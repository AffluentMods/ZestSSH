import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/mcp/mcp_protocol.dart';

/// ZestSSH's MCP server speaks both revisions AI apps use (4.1): 2026-07-28,
/// with no handshake and its method and tool name in headers too, and the
/// 2025 revisions that start with initialize. Every rule here is the
/// protocol's; no socket is opened.
void main() {
  late List<String> calls;
  late McpProtocol protocol;

  setUp(() {
    calls = [];
    protocol = McpProtocol(
      serverName: 'ZestSSH',
      serverVersion: '4.1.0',
      instructions: 'Use list_hosts first.',
      tools: () => [
        McpTool(
          name: 'echo',
          title: 'Echo',
          description: 'Says it back.',
          inputSchema: const {'type': 'object'},
          readOnly: true,
          run: (args, caller) async {
            calls.add('${caller.shownName}:${args['text']}');
            if (args['text'] == null) throw const McpArgumentError('text is required (a string)');
            if (args['text'] == 'boom') throw StateError('inside');
            return McpToolResult('${args['text']}', structured: {'text': args['text']});
          },
        ),
      ],
    );
  });

  Map<String, Object?> meta({String version = kMcpStatelessVersion}) => {
        'io.modelcontextprotocol/protocolVersion': version,
        'io.modelcontextprotocol/clientCapabilities': <String, Object?>{},
        'io.modelcontextprotocol/clientInfo': {'name': 'claude-code', 'title': 'Claude Code', 'version': '3.0'},
      };

  Future<McpResponse> post(Map<String, Object?> body, [Map<String, String> headers = const {}]) =>
      protocol.handle('POST', headers, jsonEncode(body), newSessionId: () => 'sess-1');

  Future<McpResponse> modern(String method, Map<String, Object?> params, {String? name, Map<String, String>? extra}) =>
      post({
        'jsonrpc': '2.0',
        'id': 7,
        'method': method,
        'params': {...params, '_meta': meta()},
      }, {
        'mcp-protocol-version': kMcpStatelessVersion,
        'mcp-method': method,
        'mcp-name': ?name,
        ...?extra,
      });

  group('2026-07-28', () {
    test('server/discover says what the server is, its versions and tools', () async {
      final r = await modern('server/discover', {});
      expect(r.status, 200);
      final result = r.json!['result'] as Map;
      expect(result['resultType'], 'complete');
      expect(result['supportedVersions'], containsAll([kMcpStatelessVersion, '2025-11-25']));
      expect(result['capabilities'], {'tools': {}});
      expect(result['cacheScope'], 'private');
      expect(result['ttlMs'], isA<int>());
      expect(result['instructions'], 'Use list_hosts first.');
      expect((result['_meta'] as Map)['io.modelcontextprotocol/serverInfo'], {'name': 'ZestSSH', 'version': '4.1.0'});
      expect(r.headers.containsKey('mcp-session-id'), isFalse);
    });

    test('tools/list lists the tools with their hints', () async {
      final r = await modern('tools/list', {});
      final result = r.json!['result'] as Map;
      expect(result['resultType'], 'complete');
      final tool = (result['tools'] as List).single as Map;
      expect(tool['name'], 'echo');
      expect((tool['annotations'] as Map)['readOnlyHint'], isTrue);
      expect((tool['annotations'] as Map)['destructiveHint'], isFalse);
    });

    test('tools/call runs the tool, says who asked and answers in text and JSON', () async {
      final r = await modern('tools/call', {
        'name': 'echo',
        'arguments': {'text': 'hi'},
      }, name: 'echo');
      expect(r.status, 200);
      final result = r.json!['result'] as Map;
      expect(result['resultType'], 'complete');
      expect(result['content'], [
        {'type': 'text', 'text': 'hi'},
      ]);
      expect(result['structuredContent'], {'text': 'hi'});
      expect(result.containsKey('isError'), isFalse);
      expect(calls, ['Claude Code:hi']);
    });

    test('a wrong argument and a failure inside are results with isError, the inside unsaid', () async {
      final missing = (await modern('tools/call', {'name': 'echo', 'arguments': {}}, name: 'echo')).json!['result'] as Map;
      expect(missing['isError'], isTrue);
      expect((missing['content'] as List).single, {'type': 'text', 'text': 'text is required (a string)'});
      final boom = (await modern('tools/call', {
        'name': 'echo',
        'arguments': {'text': 'boom'},
      }, name: 'echo'))
          .json!['result'] as Map;
      expect(boom['isError'], isTrue);
      expect(jsonEncode(boom), isNot(contains('inside')));
    });

    test('an unknown tool is an invalid params error', () async {
      final r = await modern('tools/call', {'name': 'nope'}, name: 'nope');
      expect(r.status, 400);
      expect((r.json!['error'] as Map)['code'], McpError.invalidParams);
    });

    test('headers that do not match the body are refused (-32020)', () async {
      final wrongName = await modern('tools/call', {'name': 'echo'}, name: 'other');
      expect(wrongName.status, 400);
      expect((wrongName.json!['error'] as Map)['code'], McpError.headerMismatch);
      final wrongMethod = await modern('tools/list', {}, extra: {'mcp-method': 'tools/call'});
      expect((wrongMethod.json!['error'] as Map)['code'], McpError.headerMismatch);
      final noVersion = await post({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/list',
        'params': {'_meta': meta()},
      }, {'mcp-method': 'tools/list'});
      expect((noVersion.json!['error'] as Map)['code'], McpError.headerMismatch);
    });

    test('a tool name sent in base64 in the header matches', () async {
      final r = await modern('tools/call', {'name': 'echo', 'arguments': {'text': 'x'}},
          name: '=?base64?${base64.encode(utf8.encode('echo'))}?=');
      expect(r.status, 200);
    });

    test('a version it does not serve: 400, -32022, with the versions it does', () async {
      final r = await post({
        'jsonrpc': '2.0',
        'id': 3,
        'method': 'tools/list',
        'params': {'_meta': meta(version: '2099-01-01')},
      }, {'mcp-protocol-version': '2099-01-01', 'mcp-method': 'tools/list'});
      expect(r.status, 400);
      final error = r.json!['error'] as Map;
      expect(error['code'], McpError.unsupportedVersion);
      expect((error['data'] as Map)['supported'], kMcpVersions);
      expect((error['data'] as Map)['requested'], '2099-01-01');
      expect(r.json!['id'], 3);
    });

    test('client capabilities missing from _meta: -32602', () async {
      final r = await post({
        'jsonrpc': '2.0',
        'id': 3,
        'method': 'tools/list',
        'params': {
          '_meta': {'io.modelcontextprotocol/protocolVersion': kMcpStatelessVersion},
        },
      }, {'mcp-protocol-version': kMcpStatelessVersion, 'mcp-method': 'tools/list'});
      expect(r.status, 400);
      expect((r.json!['error'] as Map)['code'], McpError.invalidParams);
    });

    test('an unknown method: 404 with -32601 (ping is gone in this revision)', () async {
      final r = await modern('ping', {});
      expect(r.status, 404);
      expect((r.json!['error'] as Map)['code'], McpError.methodNotFound);
    });
  });

  group('2025 revisions', () {
    test('initialize agrees a version, gives a session id, and the client\'s name is kept for its calls', () async {
      final init = await post({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {
          'protocolVersion': '2025-06-18',
          'capabilities': {},
          'clientInfo': {'name': 'cursor', 'version': '2.0'},
        },
      });
      expect(init.status, 200);
      final result = init.json!['result'] as Map;
      expect(result['protocolVersion'], '2025-06-18');
      expect(result['serverInfo'], {'name': 'ZestSSH', 'version': '4.1.0'});
      expect(result['capabilities'], {'tools': {}});
      expect(result.containsKey('resultType'), isFalse);
      expect(init.headers['mcp-session-id'], 'sess-1');

      final initialized = await post({'jsonrpc': '2.0', 'method': 'notifications/initialized'},
          {'mcp-protocol-version': '2025-06-18', 'mcp-session-id': 'sess-1'});
      expect(initialized.status, 202);
      expect(initialized.body, isNull);

      final call = await post({
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/call',
        'params': {
          'name': 'echo',
          'arguments': {'text': 'yo'},
        },
      }, {'mcp-protocol-version': '2025-06-18', 'mcp-session-id': 'sess-1'});
      expect(call.status, 200);
      expect(((call.json!['result'] as Map)['content'] as List).single, {'type': 'text', 'text': 'yo'});
      expect(calls, ['cursor:yo']);
    });

    test('a version it does not know gets the newest with a handshake', () async {
      final r = await post({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {'protocolVersion': '2024-11-05', 'capabilities': {}},
      });
      expect((r.json!['result'] as Map)['protocolVersion'], '2025-11-25');
    });

    test('ping answers, tools/list lists, an unknown MCP-Protocol-Version is refused', () async {
      expect((await post({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'})).json!['result'], {});
      final list = await post({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'}, {'mcp-protocol-version': '2025-11-25'});
      expect(((list.json!['result'] as Map)['tools'] as List).length, 1);
      final bad = await post({'jsonrpc': '2.0', 'id': 3, 'method': 'tools/list'}, {'mcp-protocol-version': '1999-01-01'});
      expect(bad.status, 400);
    });
  });

  group('JSON-RPC', () {
    test('not JSON, a batch, no jsonrpc, a null id', () async {
      final notJson = await protocol.handle('POST', const {}, '{nope', newSessionId: () => 's');
      expect(notJson.status, 400);
      expect((notJson.json!['error'] as Map)['code'], McpError.parse);
      final batch = await protocol.handle('POST', const {}, '[]', newSessionId: () => 's');
      expect((batch.json!['error'] as Map)['code'], McpError.invalidRequest);
      final noVersion = await post({'id': 1, 'method': 'ping'});
      expect((noVersion.json!['error'] as Map)['code'], McpError.invalidRequest);
      final nullId = await post({'jsonrpc': '2.0', 'id': null, 'method': 'ping'});
      expect((nullId.json!['error'] as Map)['code'], McpError.invalidRequest);
    });

    test('GET and DELETE: 405, POST only', () async {
      for (final m in ['GET', 'DELETE']) {
        final r = await protocol.handle(m, const {}, '', newSessionId: () => 's');
        expect(r.status, 405);
        expect(r.headers['allow'], 'POST');
      }
    });
  });

  test('a client\'s name is shown cut short and without control characters', () {
    expect(McpCaller.fromInfo({'name': 'evil\x1b[2Japp'}).shownName, 'evil[2Japp');
    expect(McpCaller.fromInfo({'name': 'Claude\u202E edoC'}).shownName, 'Claude edoC');
    expect(McpCaller.fromInfo({'name': 'x' * 100}).shownName!.length, 63);
    expect(McpCaller.fromInfo(null).shownName, isNull);
  });
}
