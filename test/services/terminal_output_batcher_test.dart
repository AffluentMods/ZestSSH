import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/worker/terminal_output_batcher.dart';

/// Design B terminal output batcher.
void main() {
  late List<Uint8List> batches;
  late int pauses;
  late int resumes;

  TerminalOutputBatcher make({
    int flushThreshold = 16 * 1024,
    int highWaterMark = 256 * 1024,
    int lowWaterMark = 64 * 1024,
  }) {
    batches = [];
    pauses = 0;
    resumes = 0;
    return TerminalOutputBatcher(
      onBatch: batches.add,
      onPause: () => pauses++,
      onResume: () => resumes++,
      flushThreshold: flushThreshold,
      highWaterMark: highWaterMark,
      lowWaterMark: lowWaterMark,
    );
  }

  test('chunks from the same turn coalesce into one batch', () async {
    final b = make();
    b.add(Uint8List.fromList([1]));
    b.add(Uint8List.fromList([2]));
    b.add(Uint8List.fromList([3]));
    // Not flushed synchronously: the coalesce is scheduled on a microtask.
    expect(batches, isEmpty);
    await Future.microtask(() {});
    expect(batches, hasLength(1));
    expect(batches.single, orderedEquals([1, 2, 3]));
  });

  test('separate turns each produce their own batch (echo stays prompt)',
      () async {
    final b = make();
    b.add(Uint8List.fromList([65]));
    await Future.microtask(() {});
    b.add(Uint8List.fromList([66]));
    await Future.microtask(() {});
    expect(batches, hasLength(2));
    expect(batches[0], orderedEquals([65]));
    expect(batches[1], orderedEquals([66]));
  });

  test('a chunk at the flush threshold flushes synchronously', () {
    final b = make(flushThreshold: 8);
    b.add(Uint8List(8)); // exactly the threshold
    expect(batches, hasLength(1));
    expect(batches.single, hasLength(8));
  });

  test('an empty chunk is ignored', () async {
    final b = make();
    b.add(Uint8List(0));
    await Future.microtask(() {});
    expect(batches, isEmpty);
  });

  test('crossing the high-water mark pauses reading exactly once', () {
    final b = make(flushThreshold: 10, highWaterMark: 25, lowWaterMark: 10);
    b.add(Uint8List(10)); // outstanding 10
    b.add(Uint8List(10)); // outstanding 20
    expect(pauses, 0);
    b.add(Uint8List(10)); // outstanding 30 >= 25 -> pause
    expect(pauses, 1);
    expect(b.isPaused, isTrue);
    b.add(Uint8List(10)); // still paused, no second pause callback
    expect(pauses, 1);
  });

  test('acking below the low-water mark resumes reading', () {
    final b = make(flushThreshold: 10, highWaterMark: 25, lowWaterMark: 10);
    b.add(Uint8List(10));
    b.add(Uint8List(10));
    b.add(Uint8List(10)); // outstanding 30, paused
    expect(b.isPaused, isTrue);

    b.ack(10); // outstanding 20, still above low-water
    expect(resumes, 0);
    expect(b.isPaused, isTrue);

    b.ack(15); // outstanding 5 <= 10 -> resume
    expect(resumes, 1);
    expect(b.isPaused, isFalse);
    expect(b.outstanding, 5);
  });

  test('outstanding never goes negative on an over-ack', () {
    final b = make(flushThreshold: 4);
    b.add(Uint8List(4)); // outstanding 4
    b.ack(1000);
    expect(b.outstanding, 0);
  });

  test('flush emits buffered bytes immediately', () {
    final b = make();
    b.add(Uint8List.fromList([9, 9]));
    expect(batches, isEmpty);
    b.flush();
    expect(batches.single, orderedEquals([9, 9]));
  });

  test('flush with nothing pending is a no-op', () {
    final b = make();
    b.flush();
    expect(batches, isEmpty);
  });
}
