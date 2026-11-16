import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logging/logging.dart';
import 'package:zestssh/services/automation_service.dart';

/// What the log says of a webhook names its scheme and host, never its path
/// or query, where its secret is (found in a
/// security review): the log kept the whole address, and a failure's error
/// with it, and the log's last lines go into what Copy details copies.
void main() {
  const secret = 'T0DEMO/B0DEMO/made-up-hook-token';
  const result = AutomationResult(success: true, output: 'up 3 days', error: '', exitCode: 0, elapsed: Duration.zero);

  /// What the log says while [body] runs, until every webhook line is in.
  Future<List<String>> logged(Future<void> Function() body, {int lines = 1}) async {
    final said = <String>[];
    final level = Logger.root.level;
    Logger.root.level = Level.ALL;
    final done = Completer<void>();
    final listening = Logger.root.onRecord.listen((record) {
      if (!record.message.contains('Webhook')) return;
      said.add(record.message);
      if (said.length == lines && !done.isCompleted) done.complete();
    });
    try {
      await body();
      await done.future.timeout(const Duration(seconds: 5));
    } finally {
      Logger.root.level = level;
      await listening.cancel();
    }
    return said;
  }

  Future<void> send(String url) =>
      AutomationService.sendWebhook(webhookUrl: url, connection: 'web-1', command: 'uptime', result: result);

  test('a webhook by plain http is skipped, named by its host', () async {
    final said = await logged(() => send('http://hooks.example.com/services/$secret'));
    expect(said.single, contains('http://hooks.example.com'));
    expect(said.single, isNot(contains('made-up-hook-token')));
  });

  test('sent, refused for a redirect, or failed: named by its host each time', () async {
    final answers = <http.Client Function()>[
      () => MockClient((_) async => http.Response('', 204)),
      () => MockClient((_) async =>
          http.Response('', 302, headers: {'location': 'https://elsewhere.example.com/catch/$secret'})),
      () => MockClient((request) async => throw const SocketException('Connection refused')
          .withUri(request.url)),
    ];
    for (final client in answers) {
      final said = await logged(() => http.runWithClient(() => send('https://hooks.example.com/services/$secret'), client));
      expect(said.single, contains('https://hooks.example.com'), reason: said.single);
      expect(said.single, isNot(contains('made-up-hook-token')), reason: said.single);
      expect(said.single, isNot(contains('/services/')), reason: said.single);
    }
  });

  test('what an address is named by', () {
    expect(AutomationService.webhookNamed(Uri.parse('https://hooks.example.com/services/$secret?x=1')),
        'https://hooks.example.com');
    expect(AutomationService.webhookNamed(null), '(no address)');
    expect(AutomationService.webhookNamed(Uri.parse('not an address')), '(no address)');
  });
}

extension on SocketException {
  /// The error a client throws, the way it carries the address it was for.
  Exception withUri(Uri uri) => http.ClientException('$message, uri=$uri', uri);
}
