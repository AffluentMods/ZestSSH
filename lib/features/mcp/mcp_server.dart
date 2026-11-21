/// ZestSSH's MCP server on this computer (4.1): an HTTP endpoint on
/// 127.0.0.1 that AI apps the person runs here (Claude Code, Claude Desktop,
/// Cursor, VS Code and others) call to use ZestSSH's tools.
///
/// Who may call:
///
/// * Only this computer: the server listens on 127.0.0.1 alone, never on a
///   network.
/// * Only a caller with the token: `Authorization: Bearer <token>`, compared
///   in constant time. The token is made on this computer and shown in
///   Settings; a new one ends the old.
/// * Not a web page: a browser's request names a page in `Origin` (or says
///   it is cross-site), and a page that reached 127.0.0.1 through its own
///   name (DNS rebinding) sends that name as `Host`; both are refused (403).
///
/// The protocol itself is [McpProtocol]'s.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:zestssh/features/mcp/mcp_protocol.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';

/// The endpoint's path: `http://127.0.0.1:<port>/mcp`.
const kMcpPath = '/mcp';

/// The largest request body read.
const kMcpMaxBody = 1024 * 1024;

/// A new token: 32 random bytes, base64url.
String newMcpToken() {
  final random = Random.secure();
  final bytes = List<int>.generate(32, (_) => random.nextInt(256));
  return 'zmcp_${base64Url.encode(bytes).replaceAll('=', '')}';
}

class McpServer {
  McpServer({
    required this.protocol,
    required this.token,
    required this.port,
    Future<HttpServer> Function(Object address, int port)? bind,
  }) : _bind = bind ?? ((address, port) => HttpServer.bind(address, port));

  final McpProtocol protocol;
  final String token;
  final int port;
  final Future<HttpServer> Function(Object address, int port) _bind;

  HttpServer? _server;

  /// The port listened on (the one asked for; port 0 in tests: the one given).
  int? get boundPort => _server?.port;

  bool get isRunning => _server != null;

  /// Starts listening. Throws a [SocketException] when the port is taken.
  Future<void> start() async {
    if (_server != null) return;
    final server = await _bind(InternetAddress.loopbackIPv4, port);
    server.autoCompress = false;
    server.idleTimeout = const Duration(seconds: 30);
    _server = server;
    server.listen((request) => unawaited(_handle(request)), onError: (Object e) {
      AppLogger.warning('MCP server: ${errorKind(e)}');
    });
    AppLogger.info('MCP server listening on 127.0.0.1:${server.port}');
  }

  /// Stops listening and ends the tool calls still running (their questions
  /// are taken back: what was turned off allows nothing more).
  Future<void> stop() async {
    final server = _server;
    _server = null;
    protocol.cancelAll();
    if (server == null) return;
    await server.close(force: true);
    AppLogger.info('MCP server stopped');
  }

  Future<void> _handle(HttpRequest request) async {
    final res = request.response;
    try {
      final refusal = _refusal(request);
      if (refusal != null) {
        await _drain(request);
        if (refusal == HttpStatus.unauthorized) {
          res.headers.set(HttpHeaders.wwwAuthenticateHeader, 'Bearer realm="ZestSSH"');
        }
        res.statusCode = refusal;
        // Why, as a JSON-RPC error: the SDKs show its message (with no body
        // they said only "Server returned an error response"), so a person
        // whose AI app has an old token learns where the new one is.
        final why = _refusalMessages[refusal];
        if (why != null) {
          res.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
          res.add(utf8.encode(jsonEncode({
            'jsonrpc': '2.0',
            'id': null,
            'error': {'code': McpError.invalidRequest, 'message': why},
          })));
        }
        await res.close();
        return;
      }
      final body = await _readBody(request);
      if (body == null) {
        res.statusCode = HttpStatus.requestEntityTooLarge;
        await res.close();
        return;
      }
      final headers = <String, String>{};
      request.headers.forEach((name, values) => headers[name.toLowerCase()] = values.join(','));
      final answer = await protocol.handle(request.method, headers, body, newSessionId: _newSessionId);
      res.statusCode = answer.status;
      answer.headers.forEach(res.headers.set);
      res.headers.set('cache-control', 'no-store');
      if (answer.body != null) res.add(utf8.encode(answer.body!));
      await res.close();
    } catch (e) {
      AppLogger.warning('MCP server: a request failed (${errorKind(e)})');
      try {
        res.statusCode = HttpStatus.internalServerError;
        await res.close();
      } catch (_) {}
    }
  }

  static const _refusalMessages = {
    HttpStatus.unauthorized: 'Unauthorized: the ZestSSH token is missing or wrong. ZestSSH shows the current one in '
        'Settings > AI apps (New token ends the old one).',
    HttpStatus.forbidden: 'Forbidden: ZestSSH answers only apps on this computer that call 127.0.0.1 or localhost, '
        'never a web page.',
    HttpStatus.notFound: 'Not found: the endpoint is $kMcpPath.',
  };

  /// Why [request] is refused (an HTTP status), or null to serve it.
  int? _refusal(HttpRequest request) {
    final path = request.uri.path;
    if (path != kMcpPath && path != '$kMcpPath/') return HttpStatus.notFound;
    if (!mcpHostIsLocal(request.headers.value(HttpHeaders.hostHeader))) return HttpStatus.forbidden;
    if (!mcpOriginIsLocal(request.headers.value('origin'))) return HttpStatus.forbidden;
    final site = request.headers.value('sec-fetch-site');
    if (site != null && site != 'none' && site != 'same-origin') return HttpStatus.forbidden;
    if (!mcpTokenMatches(request.headers.value(HttpHeaders.authorizationHeader), token)) {
      return HttpStatus.unauthorized;
    }
    return null;
  }

  static Future<void> _drain(HttpRequest request) async {
    try {
      await request.drain<void>();
    } catch (_) {}
  }

  /// The body as text; null when it is larger than [kMcpMaxBody].
  static Future<String?> _readBody(HttpRequest request) async {
    if (request.contentLength > kMcpMaxBody) {
      await _drain(request);
      return null;
    }
    final bytes = BytesBuilder(copy: false);
    var tooLarge = false;
    await for (final chunk in request) {
      // (Read to its end all the same, so the answer reaches the client.)
      if (tooLarge) continue;
      bytes.add(chunk);
      if (bytes.length > kMcpMaxBody) {
        tooLarge = true;
        bytes.clear();
      }
    }
    return tooLarge ? null : utf8.decode(bytes.takeBytes(), allowMalformed: true);
  }

  static String _newSessionId() {
    final random = Random.secure();
    return List<int>.generate(16, (_) => random.nextInt(256)).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

/// Whether a request's `Host` names this computer's loopback (127.0.0.1,
/// localhost or [::1], any port). A page that reached 127.0.0.1 through a
/// name of its own (DNS rebinding) sends that name.
bool mcpHostIsLocal(String? host) {
  if (host == null) return false;
  final name = host.startsWith('[')
      ? host.substring(0, host.indexOf(']') + 1)
      : host.split(':').first;
  return const {'127.0.0.1', 'localhost', '[::1]'}.contains(name.toLowerCase());
}

/// Whether a request's `Origin` is absent (an app, not a page) or a page on
/// this computer's loopback.
bool mcpOriginIsLocal(String? origin) {
  if (origin == null) return true;
  final uri = Uri.tryParse(origin);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) return false;
  return const {'127.0.0.1', 'localhost', '::1'}.contains(uri.host.toLowerCase());
}

/// Whether [authorization] is `Bearer <token>`, compared in constant time.
bool mcpTokenMatches(String? authorization, String token) {
  if (authorization == null || token.isEmpty) return false;
  const prefix = 'bearer ';
  if (authorization.length < prefix.length || authorization.substring(0, prefix.length).toLowerCase() != prefix) {
    return false;
  }
  final given = utf8.encode(authorization.substring(prefix.length).trim());
  final expected = utf8.encode(token);
  var diff = given.length ^ expected.length;
  for (var i = 0; i < expected.length; i++) {
    diff |= expected[i] ^ (i < given.length ? given[i] : 0);
  }
  return diff == 0;
}
