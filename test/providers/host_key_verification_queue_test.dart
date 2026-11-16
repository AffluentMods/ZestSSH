import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/ssh_service.dart';

/// Guards the host-key prompt QUEUE.
///
/// A workspace opening several hosts at once used to race a single-slot
/// provider: the second verification overwrote the first, the dialog's
/// busy-guard dropped it, and that session hung forever waiting for an answer
/// nobody was asked for ("only one host asks for its key"). The queue
/// serializes them: every verification is served in order and every completer
/// is resolved with exactly the answer the user gave it.
HostKeyVerification _pending(String host) => HostKeyVerification(
      host: host,
      port: 22,
      hostKey: SSHHostKey(type: 'ssh-ed25519', bytes: Uint8List(32)),
      fingerprint: 'SHA256:$host',
      isChanged: false,
      completer: Completer<bool>(),
    );

void main() {
  test('concurrent verifications are queued and served in order, each resolved',
      () async {
    final queue = HostKeyVerificationQueue();
    final a = _pending('a');
    final b = _pending('b');
    final c = _pending('c');

    // Three hosts connect "at once" - all three land in the queue.
    queue.enqueue(a);
    queue.enqueue(b);
    queue.enqueue(c);
    expect(queue.current, same(a), reason: 'the first host is asked first');

    // The user answers each in turn; the head advances every time.
    queue.resolve(a, true);
    expect(await a.completer.future, isTrue);
    expect(queue.current, same(b), reason: 'the second host is asked next');

    queue.resolve(b, false);
    expect(await b.completer.future, isFalse);
    expect(queue.current, same(c), reason: 'the third host is asked last');

    queue.resolve(c, true);
    expect(await c.completer.future, isTrue);
    expect(queue.current, isNull);
    expect(queue.state, isEmpty, reason: 'nothing is left pending or dropped');
  });

  test('a verification that arrives while one is pending is NOT dropped',
      () async {
    final queue = HostKeyVerificationQueue();
    final a = _pending('a');
    queue.enqueue(a);
    expect(queue.current, same(a));

    // A second host connects while the first prompt is still open.
    final b = _pending('b');
    queue.enqueue(b);
    expect(queue.current, same(a), reason: 'the open prompt is unchanged');

    // Answering the first surfaces the second - it was never lost.
    queue.resolve(a, true);
    expect(queue.current, same(b));
    queue.resolve(b, true);
    expect(await b.completer.future, isTrue);
  });

  test('resolve is idempotent and never re-completes a completer', () async {
    final queue = HostKeyVerificationQueue();
    final a = _pending('a');
    queue.enqueue(a);

    queue.resolve(a, false);
    // Resolving again (a stale dialog, a double tap) must not throw or flip
    // the already-delivered answer.
    queue.resolve(a, true);
    expect(await a.completer.future, isFalse);
    expect(queue.state, isEmpty);
  });

  test(
      'a pending head is visible to a FRESH read (what the desktop remount '
      'check relies on) even though a fresh listener is never notified of it',
      () async {
    // Regression for the audit finding: the desktop shell learned about
    // prompts only through ref.listen on the head provider, which fires on
    // CHANGE. If the shell was torn down mid-drain (lock-screen redirect) and
    // remounted with entries still queued, nothing ever fired and the prompt
    // was never shown - a permanent, fail-closed wedge. The fix reads the head
    // directly on mount; this pins the contract that the read sees it.
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final queue = container.read(hostKeyVerificationQueueProvider.notifier);
    final a = _pending('a');
    final b = _pending('b');
    queue.enqueue(a);
    queue.enqueue(b);

    // A listener attached AFTER entries are queued (a remounted shell) is
    // not told about the existing head, so it cannot be the only trigger.
    var notified = 0;
    container.listen<HostKeyVerification?>(
        hostKeyVerificationProvider, (_, _) => notified++);
    expect(notified, 0);

    // The mount-time read MUST see the pending head.
    expect(container.read(hostKeyVerificationProvider), same(a));

    // And once the first is answered, the next pending one is the head a
    // remounted shell must surface.
    queue.resolve(a, true);
    expect(container.read(hostKeyVerificationProvider), same(b));
  });
}
