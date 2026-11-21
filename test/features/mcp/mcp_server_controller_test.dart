import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/mcp/mcp_protocol.dart';
import 'package:zestssh/features/mcp/mcp_service.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';

/// The MCP server as Settings runs it (4.1): off until its switch is on,
/// then listening on the port set, answering an AI app that sends the
/// token; off again with the switch, and a new token ends the old one.
class _Plan extends StateNotifier<bool> implements ProStatusNotifier {
  _Plan(super.squeezed);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('without Squeezed it does not run, the switch on or not', () async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({'mcp_enabled': true, 'mcp_port': 1});
    final prefs = await SharedPreferences.getInstance();
    final tree = AppDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Plan(false)),
    ]);
    addTearDown(() async {
      container.dispose();
      await tree.close();
    });
    container.read(databaseSessionProvider.notifier).seed(tree);
    final sub = container.listen(mcpServerProvider, (_, _) {}, fireImmediately: true);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(container.read(mcpServerProvider), isA<McpOff>());
    sub.close();
  });

  test('the switch starts and stops it; an AI app with the token lists the tools', () async {
    final free = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = free.port;
    await free.close();
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({'mcp_port': port});
    final prefs = await SharedPreferences.getInstance();
    final tree = AppDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(overrides: [
      currentUserProvider.overrideWithValue(const UserProfile(uid: 'uid-me', email: 'me@example.com')),
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Plan(true)),
    ]);
    addTearDown(() async {
      container.dispose();
      await tree.close();
    });
    container.read(databaseSessionProvider.notifier).seed(tree);
    final sub = container.listen(mcpServerProvider, (_, _) {}, fireImmediately: true);
    expect(container.read(mcpServerProvider), isA<McpOff>(), reason: 'off until turned on');

    await container.read(mcpEnabledProvider.notifier).set(true);
    expect(prefs.getBool('mcp_enabled'), isTrue);
    McpStatus status = const McpStarting();
    for (var i = 0; i < 100 && status is! McpListening; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      status = container.read(mcpServerProvider);
    }
    expect(status, isA<McpListening>());
    expect((status as McpListening).port, port);

    final token = await container.read(mcpTokenProvider.future);
    expect(token, startsWith('zmcp_'));
    Future<int> listTools(String withToken) async {
      final client = HttpClient();
      try {
        final req = await client.postUrl(Uri.parse(mcpUrl(port)));
        req.headers
          ..set('authorization', 'Bearer $withToken')
          ..set('mcp-protocol-version', kMcpStatelessVersion)
          ..set('mcp-method', 'tools/list')
          ..contentType = ContentType.json;
        req.write(jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'tools/list',
          'params': {
            '_meta': {
              'io.modelcontextprotocol/protocolVersion': kMcpStatelessVersion,
              'io.modelcontextprotocol/clientCapabilities': <String, Object?>{},
            },
          },
        }));
        final res = await req.close();
        final body = await res.transform(utf8.decoder).join();
        if (res.statusCode == 200) {
          expect(((jsonDecode(body)['result'] as Map)['tools'] as List).length, 5);
        }
        return res.statusCode;
      } finally {
        client.close(force: true);
      }
    }

    expect(await listTools(token), 200);

    // A new token: the old one is refused.
    await container.read(mcpTokenProvider.notifier).renew();
    for (var i = 0; i < 100 && container.read(mcpServerProvider) is! McpListening; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(await listTools(token), 401);
    expect(await listTools(await container.read(mcpTokenProvider.future)), 200);

    await container.read(mcpEnabledProvider.notifier).set(false);
    expect(container.read(mcpServerProvider), isA<McpOff>());
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await expectLater(Socket.connect(InternetAddress.loopbackIPv4, port), throwsA(isA<SocketException>()));
    sub.close();
  });
}
