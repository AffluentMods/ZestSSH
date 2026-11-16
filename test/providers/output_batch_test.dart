import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/triggers/trigger_engine.dart';
import 'package:zestssh/providers/output_batch.dart';
import 'package:zestssh/providers/terminal_providers.dart' show sessionBytesReceivedProvider, sessionDataActivityProvider;

/// A session's output is drawn and read (the transcript, the session logs,
/// the alert rules and the two counters) once a 16 ms batch, with that
/// batch's text (found in a review). Each chunk the network delivered
/// ran all the reading on its own before.
void main() {
  testWidgets('1,000 chunks inside one 16 ms window are drawn once and read once, whole and in order', (tester) async {
    {
      final drawn = <String>[];
      final read = <(String, int)>[];
      final batch = OutputBatch(draw: drawn.add, read: (t, b) => read.add((t, b)));
      for (var i = 0; i < 1000; i++) {
        batch.add('line $i\r\n', 10);
      }
      expect(drawn, isEmpty, reason: 'nothing before the batch ends');
      expect(read, isEmpty);
      await tester.pump(const Duration(milliseconds: 16));
      final all = [for (var i = 0; i < 1000; i++) 'line $i\r\n'].join();
      expect(drawn, [all]);
      expect(read, [(all, 10000)]);
      expect(batch.waiting, isFalse);

      // The next output is a batch of its own.
      batch.add('more', 4);
      await tester.pump(const Duration(milliseconds: 16));
      expect(drawn.last, 'more');
      expect(read.last, ('more', 4));
      expect(read, hasLength(2));
    }
  });

  testWidgets('a session closed or connected again reads what waits, does not draw it, and takes nothing more', (tester) async {
    {
      final drawn = <String>[];
      final read = <(String, int)>[];
      final batch = OutputBatch(draw: drawn.add, read: (t, b) => read.add((t, b)));
      batch.add('last words', 10);
      batch.close();
      expect(read, [('last words', 10)], reason: 'the logs and the transcript keep every byte that arrived');
      expect(drawn, isEmpty, reason: 'a closed session was never drawn to');
      batch.add('after', 5);
      await tester.pump(const Duration(seconds: 1));
      expect(read, hasLength(1));
      expect(drawn, isEmpty);
    }
  });

  testWidgets('output that ended is drawn and read at once, with the character it ended inside of', (tester) async {
    {
      final drawn = <String>[];
      final read = <(String, int)>[];
      final batch = OutputBatch(draw: drawn.add, read: (t, b) => read.add((t, b)));
      batch.add('bye', 3);
      batch.finish('�');
      expect(drawn, ['bye�']);
      expect(read, [('bye�', 3)]);
      await tester.pump(const Duration(seconds: 1));
      expect(drawn, hasLength(1), reason: 'no second drawing when the 16 ms would have ended');
    }
  });

  testWidgets('a dropped connection shows what waits at once, and later output starts a new batch', (tester) async {
    {
      final drawn = <String>[];
      final batch = OutputBatch(draw: drawn.add, read: (_, _) {});
      batch.add('Connection closed', 17);
      batch.flushNow();
      expect(drawn, ['Connection closed']);
      await tester.pump(const Duration(milliseconds: 16));
      expect(drawn, hasLength(1));
      batch.add('x', 1);
      await tester.pump(const Duration(milliseconds: 16));
      expect(drawn, ['Connection closed', 'x']);
    }
  });

  testWidgets('a drawing that throws leaves the reading whole, and the next batch is drawn', (tester) async {
    {
      var throwOnce = true;
      final drawn = <String>[];
      final read = <String>[];
      final batch = OutputBatch(
        draw: (t) {
          if (throwOnce) {
            throwOnce = false;
            throw StateError('ESC [ 1 K at the first column');
          }
          drawn.add(t);
        },
        read: (t, _) => read.add(t),
      );
      batch.add('a', 1);
      await tester.pump(const Duration(milliseconds: 16));
      batch.add('b', 1);
      await tester.pump(const Duration(milliseconds: 16));
      expect(read, ['a', 'b']);
      expect(drawn, ['b']);
    }
  });

  test('measured: the alert rules on a burst of 20,000 small chunks, once a chunk against once a batch', () {
    // What processOutput does on each call (TriggerRuntime): the line
    // scanner, a work budget, and the rules on each finished line. A build
    // log arrives in small reads; at 16 ms a batch, a second of it is about
    // 60 batches.
    final rules = [
      for (final p in ['error', 'FAILED', r'\bpanic\b', r'out of memory', r'segfault'])
        CompiledTrigger.tryCompile(
          id: p,
          name: p,
          pattern: p,
          caseSensitive: false,
          notify: true,
          highlight: false,
          highlightColor: null,
          playSound: false,
          connectionId: null,
        )!,
    ];
    final chunks = [for (var i = 0; i < 20000; i++) 'gcc -c src/file_$i.c -o build/file_$i.o\r\n'];
    int scan(List<String> pieces) {
      final scanner = TriggerLineScanner();
      var calls = 0;
      for (final piece in pieces) {
        calls++;
        final budget = TriggerWorkBudget();
        for (final line in scanner.addChunk(piece)) {
          matchLine(line, rules, null, budget: budget);
        }
      }
      return calls;
    }

    final perChunk = Stopwatch()..start();
    final before = scan(chunks);
    perChunk.stop();
    final batches = <String>[];
    for (var i = 0; i < chunks.length; i += 334) {
      batches.add(chunks.sublist(i, (i + 334).clamp(0, chunks.length)).join());
    }
    final perBatch = Stopwatch()..start();
    final after = scan(batches);
    perBatch.stop();
    // ignore: avoid_print
    print('alert rules: $before calls in ${perChunk.elapsedMilliseconds} ms once a chunk, '
        '$after calls in ${perBatch.elapsedMilliseconds} ms once a batch');
    expect(before, 20000);
    expect(after, 60);
  });

  test('measured: the two counters, written once a chunk against once a batch, with a screen listening', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    var heard = 0;
    container.listen(sessionDataActivityProvider('s'), (_, _) => heard++);
    container.listen(sessionBytesReceivedProvider('s'), (_, _) => heard++);
    void write(int times, int bytes) {
      for (var i = 0; i < times; i++) {
        container.read(sessionDataActivityProvider('s').notifier).state++;
        container.read(sessionBytesReceivedProvider('s').notifier).state += bytes;
      }
    }

    final perChunk = Stopwatch()..start();
    write(20000, 40);
    perChunk.stop();
    final heardBefore = heard;
    heard = 0;
    final perBatch = Stopwatch()..start();
    write(60, 13360);
    perBatch.stop();
    // ignore: avoid_print
    print('counters: $heardBefore notifications in ${perChunk.elapsedMilliseconds} ms once a chunk, '
        '$heard in ${perBatch.elapsedMilliseconds} ms once a batch');
    expect(heardBefore, 40000);
    expect(heard, 120);
  });

  test('the connection reads its output through its batch, not once a chunk', () {
    final src = File('lib/providers/terminal_providers.dart').readAsStringSync().replaceAll('\r\n', '\n');
    final start = src.indexOf('void handleOutput(Uint8List data) {');
    expect(start, greaterThan(0));
    final body = src.substring(start, src.indexOf('\n      }\n', start));
    expect(body, contains('batch.add(text, data.length)'));
    for (final perChunk in [
      'appendOutput',
      'SessionLogService.append',
      'TeamSessionLogs.append',
      'processOutput',
      'sessionDataActivityProvider',
      'sessionBytesReceivedProvider',
    ]) {
      expect(body, isNot(contains(perChunk)), reason: '$perChunk runs once a batch, in OutputBatch.read');
    }
    // Closing a session reads what waits, so the logs keep every byte.
    expect('_outputBatches.remove(sessionId)?.close();'.allMatches(src).length, greaterThanOrEqualTo(4));
  });
}
