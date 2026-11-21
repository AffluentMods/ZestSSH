import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/mcp/mcp_protocol.dart';
import 'package:zestssh/features/mcp/mcp_requests.dart';

/// Questions from AI apps come one at a time, and the next one waits a
/// moment after the one before closes, so a double click on Run it cannot
/// answer a second command unread.
void main() {
  McpRunRequest run(String command) =>
      McpRunRequest(caller: const McpCaller(name: 'Claude Code'), hostName: 'web-01', command: command);

  test('the next question shows only after a pause once the one before is answered', () {
    fakeAsync((async) {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final first = run('uptime');
      final second = run('reboot');
      final answers = <bool>[];
      askMcp(container.read, first).then(answers.add);
      async.flushMicrotasks();
      askMcp(container.read, second).then(answers.add);
      async.flushMicrotasks();
      expect(container.read(mcpRequestProvider), same(first));

      first.reply(true);
      async.flushMicrotasks();
      expect(answers, [true]);
      // A second click now lands on nothing: the next question is not up yet.
      expect(container.read(mcpRequestProvider), isNull);
      async.elapse(kMcpQuestionGap - const Duration(milliseconds: 50));
      expect(container.read(mcpRequestProvider), isNull);
      async.elapse(const Duration(milliseconds: 100));
      expect(container.read(mcpRequestProvider), same(second));

      second.reply(false);
      async.flushMicrotasks();
      expect(answers, [true, false]);
    });
  });

  test('two waiting behind one: they still come one at a time', () {
    fakeAsync((async) {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final a = run('one');
      final b = run('two');
      final c = run('three');
      for (final r in [a, b, c]) {
        askMcp(container.read, r);
        async.flushMicrotasks();
      }
      a.reply(true);
      async.elapse(kMcpQuestionGap * 2);
      final shown = container.read(mcpRequestProvider);
      expect(shown == b || shown == c, isTrue);
      final other = identical(shown, b) ? c : b;
      expect(other.isOpen, isTrue);
      shown!.reply(true);
      async.elapse(kMcpQuestionGap * 2);
      expect(container.read(mcpRequestProvider), same(other));
      other.reply(true);
      async.flushMicrotasks();
    });
  });
}
