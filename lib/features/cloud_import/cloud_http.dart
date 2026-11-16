/// Cloud import (3.0): the one way requests reach a provider. Redirects are
/// never followed (a token would go wherever the redirect points), answers
/// are size-capped, every request times out, and when something fails the
/// details (for Copy details) say what was asked and what came back, with
/// every secret of the scan blanked out.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:zestssh/utils/type_name.dart';

/// What went wrong, in terms the import screens explain.
enum CloudErrorKind {
  /// The provider did not accept the token or keys (401).
  signIn,

  /// Accepted, but not allowed to read this (403).
  notAllowed,

  /// The address or account does not exist there (404).
  notFound,

  /// Too many requests for now (429).
  tooMany,

  /// No connection to the provider.
  offline,

  /// The provider took too long.
  timeout,

  /// The provider's certificate is not trusted (Proxmox: see its fingerprint).
  certificate,

  /// A certificate confirmed earlier is not the one presented now.
  certificateChanged,

  /// The provider failed (5xx) or answered something unexpected.
  server,

  /// The answer was not what the provider documents.
  answer,
}

class CloudError implements Exception, HasTypeName {
  CloudError(this.kind, {this.status, this.detail = ''});

  final CloudErrorKind kind;
  final int? status;

  /// For Copy details: the request, the status and the answer's start,
  /// secrets removed.
  final String detail;

  @override
  String toString() => 'CloudError(${kind.name}${status == null ? '' : ', $status'}): $detail';

  @override
  String get typeName => 'CloudError';
}

/// Sends requests for one scan. [secrets] (tokens, keys) are blanked out of
/// every error detail.
class CloudHttp {
  CloudHttp(
    this._client, {
    Iterable<String> secrets = const [],
    this.timeout = const Duration(seconds: 25),
    this.maxBytes = 16 * 1024 * 1024,
  }) : _secrets = [for (final s in secrets) if (s.length >= 6) s];

  final http.Client _client;
  final List<String> _secrets;
  final Duration timeout;
  final int maxBytes;

  /// Adds more secrets to blank out (a token obtained during the scan).
  void hide(String secret) {
    if (secret.length >= 6) _secrets.add(secret);
  }

  /// [text] with every secret replaced.
  String scrub(String text) {
    var out = text;
    for (final s in _secrets) {
      out = out.replaceAll(s, '[hidden]');
    }
    return out;
  }

  String _describe(String method, Uri url) => scrub('$method ${url.replace(userInfo: '')}');

  /// Sends [method] to [url] and returns the answer's text for a 2xx status;
  /// throws [CloudError] for anything else.
  Future<String> send(String method, Uri url, {Map<String, String> headers = const {}, String? body}) async {
    if (url.scheme != 'https') {
      throw CloudError(CloudErrorKind.notAllowed, detail: _describe(method, url));
    }
    final req = http.Request(method, url)
      ..followRedirects = false
      ..headers.addAll(headers);
    if (body != null) req.body = body;
    final String text;
    final int status;
    try {
      final res = await _client.send(req).timeout(timeout);
      status = res.statusCode;
      final bytes = <int>[];
      await for (final chunk in res.stream.timeout(timeout)) {
        bytes.addAll(chunk);
        if (bytes.length > maxBytes) {
          throw CloudError(CloudErrorKind.answer,
              status: status, detail: '${_describe(method, url)} -> $status\nThe answer is larger than ${maxBytes ~/ (1024 * 1024)} MB.');
        }
      }
      text = utf8.decode(bytes, allowMalformed: true);
    } on CloudError {
      rethrow;
    } on TimeoutException {
      throw CloudError(CloudErrorKind.timeout, detail: '${_describe(method, url)}\nNo answer within ${timeout.inSeconds} seconds.');
    } on HandshakeException catch (e) {
      throw CloudError(CloudErrorKind.certificate, detail: scrub('${_describe(method, url)}\n$e'));
    } on TlsException catch (e) {
      throw CloudError(CloudErrorKind.certificate, detail: scrub('${_describe(method, url)}\n$e'));
    } on SocketException catch (e) {
      throw CloudError(CloudErrorKind.offline, detail: scrub('${_describe(method, url)}\n$e'));
    } on http.ClientException catch (e) {
      final certificate = e.message.contains('CERTIFICATE') || e.message.contains('Handshake');
      throw CloudError(certificate ? CloudErrorKind.certificate : CloudErrorKind.offline,
          detail: scrub('${_describe(method, url)}\n${e.message}'));
    }
    if (status >= 200 && status < 300) return text;
    final head = text.length > 2000 ? '${text.substring(0, 2000)}...' : text;
    final detail = scrub('${_describe(method, url)} -> $status\n$head');
    throw CloudError(
      switch (status) {
        401 => CloudErrorKind.signIn,
        403 => CloudErrorKind.notAllowed,
        404 => CloudErrorKind.notFound,
        429 => CloudErrorKind.tooMany,
        _ => CloudErrorKind.server,
      },
      status: status,
      detail: detail,
    );
  }

  /// [send] with a JSON answer.
  Future<Object?> json(String method, Uri url, {Map<String, String> headers = const {}, String? body}) async {
    final text = await send(method, url, headers: {'Accept': 'application/json', ...headers}, body: body);
    try {
      return jsonDecode(text);
    } on FormatException {
      final head = text.length > 500 ? '${text.substring(0, 500)}...' : text;
      throw CloudError(CloudErrorKind.answer, detail: scrub('${_describe(method, url)}\nNot JSON:\n$head'));
    }
  }
}
