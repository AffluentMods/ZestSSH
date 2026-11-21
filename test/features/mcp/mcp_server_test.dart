import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/mcp/mcp_protocol.dart';
import 'package:zestssh/features/mcp/mcp_server.dart';

/// Who may reach ZestSSH's MCP server (4.1): this computer only (127.0.0.1),
/// only with the token, and never a web page (an Origin of another site, a
/// Host that is not this computer's loopback, a cross-site fetch).
void main() {
  const token = 'zmcp_test-token-123';
  late McpServer server;
  late HttpClient client;

  setUp(() async {
    server = McpServer(
      protocol: McpProtocol(
        serverName: 'ZestSSH',
        serverVersion: '4.1.0',
        instructions: '',
        tools: () => const [],
      ),
      token: token,
      port: 0,
    );
    await server.start();
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
  });

  Future<(int, String)> send({
    String method = 'POST',
    String path = '/mcp',
    String? auth = 'Bearer $token',
    Map<String, String> headers = const {},
    String body = '{"jsonrpc":"2.0","id":1,"method":"ping"}',
  }) async {
    final req = await client.openUrl(method, Uri.parse('http://127.0.0.1:${server.boundPort}$path'));
    if (auth != null) req.headers.set(HttpHeaders.authorizationHeader, auth);
    headers.forEach(req.headers.set);
    req.headers.contentType = ContentType.json;
    req.write(body);
    final res = await req.close();
    return (res.statusCode, await res.transform(utf8.decoder).join());
  }

  test('listens on 127.0.0.1 only', () async {
    expect(server.isRunning, isTrue);
    final others = await NetworkInterface.list(type: InternetAddressType.IPv4);
    for (final address in [for (final i in others) ...i.addresses]) {
      if (address.isLoopback) continue;
      await expectLater(Socket.connect(address, server.boundPort!, timeout: const Duration(seconds: 2)),
          throwsA(isA<SocketException>()));
    }
  });

  test('with the token: served', () async {
    final (status, body) = await send();
    expect(status, 200);
    expect(jsonDecode(body)['result'], {});
  });

  test('no token, a wrong one, or one cut short: 401', () async {
    expect((await send(auth: null)).$1, 401);
    expect((await send(auth: 'Bearer nope')).$1, 401);
    expect((await send(auth: 'Bearer zmcp_test-token-12')).$1, 401);
    expect((await send(auth: 'Basic $token')).$1, 401);
  });

  test('a refusal says why in a JSON-RPC error, which the SDKs show (a wrong token: where the current one is)', () async {
    String why((int, String) answer) => ((jsonDecode(answer.$2) as Map)['error'] as Map)['message'] as String;
    final wrong = await send(auth: 'Bearer zmcp_old-token');
    expect(wrong.$1, 401);
    expect(why(wrong), allOf(contains('token'), contains('Settings > AI apps')));
    expect(wrong.$2, isNot(contains(token)));
    expect(why(await send(headers: {'origin': 'https://evil.example'})), contains('never a web page'));
    expect(why(await send(path: '/')), contains('/mcp'));
  });

  test('a web page cannot use it: another Origin, a rebound Host, a cross-site fetch', () async {
    expect((await send(headers: {'origin': 'https://evil.example'})).$1, 403);
    expect((await send(headers: {'origin': 'null'})).$1, 403);
    expect((await send(headers: {'host': 'evil.example:80'})).$1, 403);
    expect((await send(headers: {'sec-fetch-site': 'cross-site'})).$1, 403);
    expect((await send(headers: {'origin': 'http://localhost:3000'})).$1, 200);
  });

  test('other paths: 404; a body over 1 MB: 413', () async {
    expect((await send(path: '/')).$1, 404);
    expect((await send(path: '/mcpx')).$1, 404);
    expect((await send(body: 'x' * (kMcpMaxBody + 1))).$1, 413);
  });

  test('the checks of Host, Origin and the token', () {
    expect(mcpHostIsLocal('127.0.0.1:47390'), isTrue);
    expect(mcpHostIsLocal('localhost'), isTrue);
    expect(mcpHostIsLocal('[::1]:80'), isTrue);
    expect(mcpHostIsLocal('127.0.0.1.evil.example'), isFalse);
    expect(mcpHostIsLocal(null), isFalse);
    expect(mcpOriginIsLocal(null), isTrue);
    expect(mcpOriginIsLocal('http://127.0.0.1:8080'), isTrue);
    expect(mcpOriginIsLocal('file://'), isFalse);
    expect(mcpTokenMatches('bearer $token', token), isTrue);
    expect(mcpTokenMatches('Bearer ${token}x', token), isFalse);
    expect(mcpTokenMatches('Bearer anything', ''), isFalse);
    expect(newMcpToken(), startsWith('zmcp_'));
    expect(newMcpToken(), isNot(newMcpToken()));
    expect(newMcpToken().length, greaterThan(40));
  });

  test('a port in use: start throws, so Settings can say so', () async {
    final other = McpServer(
      protocol: McpProtocol(serverName: 'x', serverVersion: 'x', instructions: '', tools: () => const []),
      token: token,
      port: server.boundPort!,
    );
    await expectLater(other.start(), throwsA(isA<SocketException>()));
  });
}
