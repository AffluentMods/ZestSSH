/// The Model Context Protocol, as ZestSSH's own MCP server speaks it (4.1):
/// JSON-RPC over HTTP, one JSON answer to each request, tools only.
///
/// Two revisions of the protocol are served, as AI apps speak either:
///
/// * 2026-07-28, which has no handshake: every request carries its version
///   and what the client can do in `params._meta`, and its method (and a
///   tool call's name) in headers as well. `server/discover` says what this
///   server is.
/// * 2025-11-25 and the revisions before it back to 2025-03-26: `initialize`,
///   then `notifications/initialized`, then requests that carry the agreed
///   version in the `MCP-Protocol-Version` header.
///
/// Nothing here touches the network or the app: [McpProtocol.handle] takes a
/// request's method, headers and body and answers with a status, headers and
/// a body, so that every rule of the protocol is tested without a socket.
/// Who may call (the token, where a request comes from) is the server's
/// ([McpServer]).
library;

import 'dart:async';
import 'dart:convert';

import 'package:zestssh/utils/type_name.dart';

/// The revision with no handshake.
const kMcpStatelessVersion = '2026-07-28';

/// The revisions served, newest first.
const kMcpVersions = [kMcpStatelessVersion, '2025-11-25', '2025-06-18', '2025-03-26'];

/// The revisions that start with `initialize`.
const kMcpHandshakeVersions = ['2025-11-25', '2025-06-18', '2025-03-26'];

const _metaVersion = 'io.modelcontextprotocol/protocolVersion';
const _metaCapabilities = 'io.modelcontextprotocol/clientCapabilities';
const _metaClientInfo = 'io.modelcontextprotocol/clientInfo';
const _metaServerInfo = 'io.modelcontextprotocol/serverInfo';

/// JSON-RPC and MCP error codes.
abstract final class McpError {
  static const parse = -32700;
  static const invalidRequest = -32600;
  static const methodNotFound = -32601;
  static const invalidParams = -32602;
  static const internal = -32603;
  static const headerMismatch = -32020;
  static const unsupportedVersion = -32022;
}

/// Who is calling, as far as the server knows: the name and version the
/// client gave of itself (an AI app says what it likes; it is shown as what
/// it says it is, never trusted for anything).
class McpCaller {
  const McpCaller({this.name, this.version, this.cancelled});

  final String? name;
  final String? version;

  /// Completes when the AI app gives up on the tool call this caller makes
  /// (in the 2025 revisions it says so with `notifications/cancelled`, as
  /// the SDKs do after their own time limit, a minute by default), so that
  /// a question still waiting for the person is taken back. Null: there is
  /// no way to know.
  final Future<void>? cancelled;

  /// This caller for one tool call, which [cancelled] ends.
  McpCaller during(Future<void> cancelled) => McpCaller(name: name, version: version, cancelled: cancelled);

  /// The name to show the person: what the client said, cut short, or null.
  String? get shownName {
    final n = name?.trim();
    if (n == null || n.isEmpty) return null;
    // Control characters, and invisible format ones (direction overrides,
    // zero-width characters) that could make the name read as another.
    final clean = n.replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]|\p{Cf}', unicode: true), '');
    return clean.length > 60 ? '${clean.substring(0, 60)}...' : clean;
  }

  static McpCaller fromInfo(Object? info) {
    if (info is! Map) return const McpCaller();
    final name = info['title'] is String ? info['title'] as String : info['name'];
    return McpCaller(
      name: name is String ? name : null,
      version: info['version'] is String ? info['version'] as String : null,
    );
  }
}

/// What a tool gave back: [text] for the model to read, [structured] as the
/// same in JSON where the tool has some, and [isError] where it could not do
/// what it was asked (the model reads why and may try otherwise).
class McpToolResult {
  const McpToolResult(this.text, {this.structured, this.isError = false});

  const McpToolResult.error(this.text)
      : structured = null,
        isError = true;

  final String text;
  final Object? structured;
  final bool isError;
}

/// One tool an AI app may call.
class McpTool {
  const McpTool({
    required this.name,
    required this.title,
    required this.description,
    required this.inputSchema,
    required this.run,
    this.readOnly = false,
    this.destructive = false,
    this.idempotent = false,
  });

  final String name;
  final String title;
  final String description;
  final Map<String, Object?> inputSchema;
  final bool readOnly;
  final bool destructive;
  final bool idempotent;
  final Future<McpToolResult> Function(Map<String, Object?> arguments, McpCaller caller) run;

  Map<String, Object?> toJson() => {
        'name': name,
        'title': title,
        'description': description,
        'inputSchema': inputSchema,
        'annotations': {
          'title': title,
          'readOnlyHint': readOnly,
          'destructiveHint': destructive,
          'idempotentHint': idempotent,
          // Hosts are other computers: what a tool does reaches past ZestSSH.
          'openWorldHint': true,
        },
      };
}

/// An answer: [status], [body] (null for none) and [headers].
class McpResponse {
  const McpResponse(this.status, {this.body, this.headers = const {}});

  final int status;
  final String? body;
  final Map<String, String> headers;

  /// The body as JSON, for tests.
  Map<String, Object?>? get json => body == null ? null : jsonDecode(body!) as Map<String, Object?>;
}

/// The protocol: what to answer each request.
class McpProtocol {
  McpProtocol({
    required this.serverName,
    required this.serverVersion,
    required this.instructions,
    required List<McpTool> Function() tools,
  }) : _tools = tools;

  final String serverName;
  final String serverVersion;
  final String instructions;
  final List<McpTool> Function() _tools;

  /// Callers that came through `initialize` (2025 revisions), by the session
  /// id given them, so a later tool call can say who asks. Only for showing
  /// a name: a request with no session id or an unknown one is served the
  /// same. The last [_maxSessions] are kept.
  final _sessions = <String, McpCaller>{};
  static const _maxSessions = 32;
  int _sessionCount = 0;

  /// Tool calls still running, by the session id the client sent (none: an
  /// empty one) and the request's id, each with what ends it when the
  /// client cancels it.
  final _calls = <String, Completer<void>>{};

  static String _callKey(String? session, Object id) => '${session ?? ''} ${jsonEncode(id)}';

  /// Ends every tool call still running, as if each client cancelled it: the
  /// server stopped (AI apps turned off, a new token, the plan ended), so a
  /// question still waiting for the person is taken back and nothing it
  /// asked about happens.
  void cancelAll() {
    final calls = [..._calls.values];
    _calls.clear();
    for (final c in calls) {
      if (!c.isCompleted) c.complete();
    }
  }

  /// Answers one HTTP request to the endpoint. [headers] have lower case
  /// names. [newSessionId] makes the id given to a client that initializes.
  Future<McpResponse> handle(
    String method,
    Map<String, String> headers,
    String body, {
    required String Function() newSessionId,
  }) async {
    if (method == 'GET' || method == 'DELETE') {
      return const McpResponse(405, headers: {'allow': 'POST'});
    }
    if (method != 'POST') return const McpResponse(405, headers: {'allow': 'POST'});

    final Object? message;
    try {
      message = jsonDecode(body);
    } on FormatException {
      return _error(400, null, McpError.parse, 'Parse error');
    }
    if (message is List) {
      return _error(400, null, McpError.invalidRequest, 'Batches are not supported');
    }
    if (message is! Map<String, Object?> || message['jsonrpc'] != '2.0') {
      return _error(400, null, McpError.invalidRequest, 'Not a JSON-RPC 2.0 message');
    }
    final rpcMethod = message['method'];
    final hasId = message.containsKey('id');
    final id = message['id'];

    // A response or a notification from the client: nothing to answer.
    if (rpcMethod == null) {
      if (message.containsKey('result') || message.containsKey('error')) return const McpResponse(202);
      return _error(400, null, McpError.invalidRequest, 'No method');
    }
    if (rpcMethod is! String) return _error(400, null, McpError.invalidRequest, 'The method is not a string');
    if (!hasId) {
      // The client gave up on a request (its own time limit, or its person
      // stopped it): a call of the same session with that id is ended.
      if (rpcMethod == 'notifications/cancelled') {
        final params = message['params'];
        final requestId = params is Map ? params['requestId'] : null;
        if (requestId is String || requestId is num) {
          final call = _calls.remove(_callKey(headers['mcp-session-id'], requestId!));
          if (call != null && !call.isCompleted) call.complete();
        }
      }
      return const McpResponse(202);
    }
    if (id == null || (id is! String && id is! num)) {
      return _error(400, null, McpError.invalidRequest, 'A request id must be a string or a number');
    }

    final params = message['params'];
    if (params != null && params is! Map<String, Object?>) {
      return _error(400, id, McpError.invalidParams, 'params must be an object');
    }
    final p = (params as Map<String, Object?>?) ?? const <String, Object?>{};
    final meta = p['_meta'];
    final modern = meta is Map && meta.containsKey(_metaVersion);

    if (modern) return _handleStateless(rpcMethod, id, p, meta, headers);
    return _handleHandshake(rpcMethod, id, p, headers, newSessionId);
  }

  // ── 2026-07-28 ────────────────────────────────────────────────────

  Future<McpResponse> _handleStateless(
    String method,
    Object id,
    Map<String, Object?> params,
    Map<dynamic, dynamic> meta,
    Map<String, String> headers,
  ) async {
    final version = meta[_metaVersion];
    if (version is! String) {
      return _error(400, id, McpError.invalidParams, 'The protocol version must be a string');
    }
    if (version != kMcpStatelessVersion) {
      // An older revision named in _meta, or one this server does not know.
      return _error(400, id, McpError.unsupportedVersion, 'Unsupported protocol version',
          data: {'supported': kMcpVersions, 'requested': version});
    }
    if (meta[_metaCapabilities] is! Map) {
      return _error(400, id, McpError.invalidParams, 'Missing $_metaCapabilities');
    }
    if (headers['mcp-protocol-version'] != version) {
      return _error(400, id, McpError.headerMismatch, 'MCP-Protocol-Version does not match the request');
    }
    if (headers['mcp-method'] != method) {
      return _error(400, id, McpError.headerMismatch, 'Mcp-Method does not match the request');
    }
    if (method == 'tools/call') {
      final name = params['name'];
      if (name is! String || _decodeHeaderName(headers['mcp-name']) != name) {
        return _error(400, id, McpError.headerMismatch, 'Mcp-Name does not match the request');
      }
    }
    final caller = McpCaller.fromInfo(meta[_metaClientInfo]);

    switch (method) {
      case 'server/discover':
        return _result(id, {
          'resultType': 'complete',
          'supportedVersions': kMcpVersions,
          'capabilities': {'tools': <String, Object?>{}},
          'ttlMs': 60000,
          'cacheScope': 'private',
          'instructions': instructions,
          '_meta': {
            _metaServerInfo: {'name': serverName, 'version': serverVersion},
          },
        });
      case 'tools/list':
        return _result(id, {
          'resultType': 'complete',
          'tools': [for (final t in _tools()) t.toJson()],
          'ttlMs': 60000,
          'cacheScope': 'private',
        });
      case 'tools/call':
        return _call(id, params, caller, headers['mcp-session-id'], stateless: true);
      default:
        return _error(404, id, McpError.methodNotFound, 'Method not found: $method');
    }
  }

  /// A header value that is `=?base64?...?=` is the name in base64 (a name
  /// that is not plain ASCII).
  static String? _decodeHeaderName(String? value) {
    if (value == null) return null;
    final m = RegExp(r'^=\?base64\?(.*)\?=$').firstMatch(value);
    if (m == null) return value;
    try {
      return utf8.decode(base64.decode(m.group(1)!));
    } on FormatException {
      return null;
    }
  }

  // ── 2025 revisions (initialize) ───────────────────────────────────

  Future<McpResponse> _handleHandshake(
    String method,
    Object id,
    Map<String, Object?> params,
    Map<String, String> headers,
    String Function() newSessionId,
  ) async {
    if (method == 'initialize') {
      final asked = params['protocolVersion'];
      if (asked is! String) {
        return _error(400, id, McpError.invalidParams, 'protocolVersion is missing');
      }
      // The version asked for where served, else the newest one with a
      // handshake (the client decides whether it can go on).
      final agreed = kMcpHandshakeVersions.contains(asked) ? asked : kMcpHandshakeVersions.first;
      final sessionId = newSessionId();
      _sessions[sessionId] = McpCaller.fromInfo(params['clientInfo']);
      if (++_sessionCount > _maxSessions) _sessions.remove(_sessions.keys.first);
      return _result(
        id,
        {
          'protocolVersion': agreed,
          'capabilities': {'tools': <String, Object?>{}},
          'serverInfo': {'name': serverName, 'version': serverVersion},
          'instructions': instructions,
        },
        headers: {'mcp-session-id': sessionId},
      );
    }

    // After initialize: the header names the agreed version (none: the
    // oldest, 2025-03-26, which had no header).
    final version = headers['mcp-protocol-version'];
    if (version != null && !kMcpHandshakeVersions.contains(version)) {
      return _error(400, id, McpError.invalidRequest, 'Unsupported MCP-Protocol-Version: $version',
          data: {'supported': kMcpVersions, 'requested': version});
    }
    final caller = _sessions[headers['mcp-session-id']] ?? const McpCaller();

    switch (method) {
      case 'ping':
        return _result(id, const <String, Object?>{});
      case 'tools/list':
        return _result(id, {
          'tools': [for (final t in _tools()) t.toJson()],
        });
      case 'tools/call':
        return _call(id, params, caller, headers['mcp-session-id'], stateless: false);
      default:
        return _error(200, id, McpError.methodNotFound, 'Method not found: $method');
    }
  }

  // ── Both ──────────────────────────────────────────────────────────

  Future<McpResponse> _call(Object id, Map<String, Object?> params, McpCaller caller, String? session,
      {required bool stateless}) async {
    final name = params['name'];
    if (name is! String) return _error(stateless ? 400 : 200, id, McpError.invalidParams, 'name is missing');
    final tool = _tools().where((t) => t.name == name).firstOrNull;
    if (tool == null) return _error(stateless ? 400 : 200, id, McpError.invalidParams, 'Unknown tool: $name');
    final arguments = params['arguments'];
    if (arguments != null && arguments is! Map<String, Object?>) {
      return _toolResult(id, const McpToolResult.error('arguments must be an object'), stateless: stateless);
    }
    final key = _callKey(session, id);
    final cancelled = Completer<void>();
    _calls[key] = cancelled;
    McpToolResult result;
    try {
      result = await tool.run((arguments as Map<String, Object?>?) ?? const {}, caller.during(cancelled.future));
    } on McpArgumentError catch (e) {
      result = McpToolResult.error(e.message);
    } catch (e) {
      // What went wrong inside the app is not the model's to read in full.
      result = const McpToolResult.error('ZestSSH could not do this. Nothing was sent to a host.');
    } finally {
      if (identical(_calls[key], cancelled)) _calls.remove(key);
    }
    return _toolResult(id, result, stateless: stateless);
  }

  McpResponse _toolResult(Object id, McpToolResult r, {required bool stateless}) => _result(id, {
        if (stateless) 'resultType': 'complete',
        'content': [
          {'type': 'text', 'text': r.text},
        ],
        if (r.structured != null) 'structuredContent': r.structured,
        if (r.isError) 'isError': true,
      });

  static McpResponse _result(Object id, Object result, {Map<String, String> headers = const {}}) => McpResponse(
        200,
        body: jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}),
        headers: {'content-type': 'application/json', ...headers},
      );

  static McpResponse _error(int status, Object? id, int code, String message, {Object? data}) => McpResponse(
        status,
        body: jsonEncode({
          'jsonrpc': '2.0',
          'id': ?id,
          'error': {'code': code, 'message': message, 'data': ?data},
        }),
        headers: const {'content-type': 'application/json'},
      );
}

/// A tool's argument is missing or wrong: the model is told [message].
class McpArgumentError implements Exception, HasTypeName {
  const McpArgumentError(this.message);

  final String message;

  @override
  String get typeName => 'McpArgumentError';

  @override
  String toString() => 'McpArgumentError: $message';
}

/// Reads tool arguments, saying plainly which one is wrong.
extension McpArguments on Map<String, Object?> {
  String requireString(String key) {
    final v = this[key];
    if (v is! String || v.trim().isEmpty) throw McpArgumentError('$key is required (a string)');
    return v;
  }

  String? optionalString(String key) {
    final v = this[key];
    if (v == null) return null;
    if (v is! String) throw McpArgumentError('$key must be a string');
    return v;
  }

  int optionalInt(String key, {required int fallback, required int min, required int max}) {
    final v = this[key];
    if (v == null) return fallback;
    if (v is! num || v != v.roundToDouble()) throw McpArgumentError('$key must be a whole number');
    if (v < min || v > max) throw McpArgumentError('$key must be from $min to $max');
    return v.toInt();
  }
}
