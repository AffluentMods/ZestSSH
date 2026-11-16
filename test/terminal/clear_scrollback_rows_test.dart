import 'dart:math';
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:xterm/src/utils/circular_buffer.dart';
import 'package:xterm/xterm.dart';

/// A bug in 2.2.1: after `clear`, copying a selection picked up old
/// text. `clear` erases the screen
/// and removes the scrollback. The list that holds the rows removed them by
/// moving its start, and did not move the start every row measures its place
/// from: each row left on screen then took itself to be as many rows further
/// down as the scrollback had lines, and the removed rows still counted as
/// there. A selection dragged over the screen after a `clear` stood that
/// many rows lower: the highlight appeared somewhere else (or off the
/// screen), and what was copied was whatever those other rows held, mostly
/// nothing. It lasted until a screenful of new output had replaced the rows.

Terminal _screen({int width = 40, int height = 8, int maxLines = 200}) {
  final t = Terminal(maxLines: maxLines);
  t.resize(width, height);
  return t;
}

/// Every row must know it is in the buffer and where: a selection, a search
/// match and a highlight all stand on that.
void _expectRowsKnowTheirPlace(Terminal t, {String reason = ''}) {
  final lines = t.buffer.lines;
  for (var i = 0; i < lines.length; i++) {
    expect(lines[i].attached, isTrue, reason: '$reason row $i is in the buffer');
    expect(lines[i].index, i, reason: '$reason row $i knows its place');
  }
}

/// What dragging over columns [from]..[to] of screen row [row] selects.
String? _dragged(Terminal t, int row, int from, int to) {
  final y = t.buffer.scrollBack + row;
  final c = TerminalController();
  c.setSelection(t.buffer.createAnchor(from, y), t.buffer.createAnchor(to, y));
  final range = c.selection;
  if (range == null) return null;
  expect(range.begin.y, y, reason: 'the selection is on the row that was dragged over');
  expect(range.end.y, y);
  return t.buffer.getText(range);
}

const _clear = '\x1b[H\x1b[2J\x1b[3J';

class _Item with IndexedItem {
  _Item(this.name);
  final int name;
  @override
  String toString() => 'item $name';
}

void main() {
  group('after clear', () {
    test('every row on screen knows its place, and what is dragged over is what is selected', () {
      final t = _screen();
      for (var i = 0; i < 30; i++) {
        t.write('line $i\r\n');
      }
      expect(t.buffer.scrollBack, 23);
      t.write(_clear);
      t.write('prompt# hello world');
      expect(t.buffer.height, 8);
      expect(t.buffer.scrollBack, 0);
      _expectRowsKnowTheirPlace(t);
      expect(_dragged(t, 0, 8, 13), 'hello');
      expect(_dragged(t, 0, 14, 19), 'world');
    });

    test('and after the next clear, and the next, with output between', () {
      final t = _screen();
      for (var round = 0; round < 5; round++) {
        for (var i = 0; i < 11 + round * 7; i++) {
          t.write('round $round line $i\r\n');
        }
        t.write(_clear);
        t.write('prompt# round $round');
        _expectRowsKnowTheirPlace(t, reason: 'round $round:');
        expect(_dragged(t, 0, 8, 15), 'round $round');
        // A few lines, fewer than a screen: the rows of the cleared screen
        // are still the ones shown.
        t.write('\r\nwget https://files.example/disk.iso\r\nsaved');
        _expectRowsKnowTheirPlace(t, reason: 'round $round, after output:');
        expect(_dragged(t, 1, 5, 35), 'https://files.example/disk.iso');
        expect(_dragged(t, 2, 0, 5), 'saved');
        t.write('\r\n');
      }
    });

    test('with a scrollback that had filled up and wrapped around', () {
      final t = _screen(maxLines: 20);
      for (var i = 0; i < 100; i++) {
        t.write('line $i\r\n');
      }
      expect(t.buffer.height, 20);
      t.write(_clear);
      t.write('prompt# hello');
      _expectRowsKnowTheirPlace(t);
      expect(_dragged(t, 0, 8, 13), 'hello');
      // And output goes on as ever, past the end of what is kept.
      for (var i = 0; i < 50; i++) {
        t.write('\r\nmore $i');
      }
      _expectRowsKnowTheirPlace(t);
      expect(_dragged(t, 7, 0, 7), 'more 49');
      expect(_dragged(t, 0, 0, 7), 'more 42');
    });

    test('the rows that were removed are gone: nothing anchored to them stands', () {
      final t = _screen();
      for (var i = 0; i < 30; i++) {
        t.write('line $i\r\n');
      }
      final c = TerminalController();
      // A search match (a highlight) and a selection, both in the scrollback.
      final match = c.highlight(
        p1: t.buffer.createAnchor(0, 3),
        p2: t.buffer.createAnchor(6, 3),
        color: const Color(0xFF00FF00),
      );
      c.setSelection(t.buffer.createAnchor(0, 5), t.buffer.createAnchor(6, 5));
      expect(match.range, isNotNull);
      expect(t.buffer.getText(c.selection), 'line 5');
      final removed = t.buffer.lines[3];

      t.write(_clear);
      expect(removed.attached, isFalse, reason: 'a removed row is not in the buffer');
      expect(match.range, isNull, reason: 'a highlight on a removed row is not drawn anywhere');
      expect(c.selection, isNull);
    });

    test('the scrollback alone (ESC [ 3 J) leaves the screen as it is, rows in place', () {
      final t = _screen();
      for (var i = 0; i < 30; i++) {
        t.write('line $i\r\n');
      }
      t.write('\x1b[3J');
      expect(t.buffer.height, 8);
      _expectRowsKnowTheirPlace(t);
      expect(_dragged(t, 0, 0, 7), 'line 23');
      expect(_dragged(t, 6, 0, 7), 'line 29');
    });

    test('a full-screen program whose window changes height keeps no scrollback, rows in place', () {
      final t = _screen();
      t.write('\x1b[?1049h');
      for (var i = 0; i < 8; i++) {
        t.write('\x1b[${i + 1};1Hrow$i');
      }
      // Shorter: the top rows would go to a scrollback the full screen does
      // not keep.
      t.resize(40, 5);
      _expectRowsKnowTheirPlace(t, reason: 'shorter:');
      expect(t.buffer.height, 5);
      for (var row = 0; row < 5; row++) {
        final text = t.buffer.lines[row].getText();
        expect(_dragged(t, row, 0, text.length), text, reason: 'row $row');
      }
      t.resize(40, 9);
      _expectRowsKnowTheirPlace(t, reason: 'taller:');
    });
  });

  group('the list that holds the rows', () {
    test('removing from the start: the rest know their new place and the removed know they left', () {
      final list = IndexAwareCircularBuffer<_Item>(10);
      final items = [for (var i = 0; i < 8; i++) _Item(i)];
      list.pushAll(items);
      list.trimStart(3);
      expect(list.length, 5);
      for (var i = 0; i < 5; i++) {
        expect(identical(list[i], items[i + 3]), isTrue);
        expect(list[i].index, i);
        expect(list[i].attached, isTrue);
      }
      for (var i = 0; i < 3; i++) {
        expect(items[i].attached, isFalse, reason: 'item $i left the list');
      }
      // More than there is: all of it, and no further.
      list.trimStart(99);
      expect(list.length, 0);
      expect(items.every((x) => !x.attached), isTrue);
      list.trimStart(1);
      expect(list.length, 0);
      // And it goes on as a list.
      final next = _Item(100);
      list.push(next);
      expect(next.index, 0);
      expect(identical(list[0], next), isTrue);
    });

    test('any run of changes: what is read, where each element says it is, and what left', () {
      // Every way the list is changed, in a long random order, against a
      // plain list that does the same. After each change the two hold the
      // same elements, every element knows its index, and every element
      // that left knows it left.
      for (final capacity in [1, 2, 3, 5, 8, 16]) {
        final random = Random(capacity * 7919);
        final list = IndexAwareCircularBuffer<_Item>(capacity);
        final model = <_Item>[];
        final all = <_Item>[];
        var made = 0;
        _Item make() {
          final item = _Item(made++);
          all.add(item);
          return item;
        }

        void push(_Item item) {
          if (model.length == capacity) model.removeAt(0);
          model.add(item);
        }

        for (var step = 0; step < 4000; step++) {
          final op = random.nextInt(11);
          var did = 'nothing';
          switch (op) {
            case 0:
            case 1:
            case 2:
              final item = make();
              list.push(item);
              push(item);
              did = 'push';
            case 3:
              if (model.isEmpty) break;
              final n = random.nextInt(model.length + 2);
              list.trimStart(n);
              model.removeRange(0, min(n, model.length));
              did = 'trimStart($n)';
            case 4:
              final at = random.nextInt(model.length + 1);
              final item = make();
              list.insert(at, item);
              if (at == model.length) {
                push(item);
              } else if (at == 0 && model.length >= capacity) {
                // Put in first and dropped at once: nothing changes.
              } else {
                model.insert(at, item);
                if (model.length > capacity) model.removeAt(0);
              }
              did = 'insert($at)';
            case 5:
              if (model.isEmpty) break;
              final at = random.nextInt(model.length);
              final n = 1 + random.nextInt(3);
              list.remove(at, n);
              model.removeRange(at, min(at + n, model.length));
              did = 'remove($at, $n)';
            case 6:
              if (model.isEmpty) break;
              list.pop();
              model.removeLast();
              did = 'pop';
            case 7:
              if (model.isEmpty) break;
              final start = random.nextInt(model.length);
              final end = start + random.nextInt(model.length - start);
              final n = 1 + random.nextInt(3);
              final moved = min(n, end - start + 1);
              list.shiftUp(start, end, n, make);
              final fresh = all.sublist(all.length - moved);
              model.removeRange(start, start + moved);
              model.insertAll(end - moved + 1, fresh);
              did = 'shiftUp($start, $end, $n)';
            case 8:
              if (model.isEmpty) break;
              final start = random.nextInt(model.length);
              final end = start + random.nextInt(model.length - start);
              final n = 1 + random.nextInt(3);
              final moved = min(n, end - start + 1);
              list.shiftDown(start, end, n, make);
              final fresh = all.sublist(all.length - moved);
              model.removeRange(end - moved + 1, end + 1);
              model.insertAll(start, fresh);
              did = 'shiftDown($start, $end, $n)';
            case 9:
              if (model.isEmpty) break;
              final at = random.nextInt(model.length);
              final item = make();
              if (random.nextBool()) {
                list[at] = item;
              } else {
                list.swap(at, item);
              }
              model[at] = item;
              did = 'replace($at)';
            case 10:
              if (random.nextInt(12) == 0) {
                list.clear();
                model.clear();
                did = 'clear';
              } else if (random.nextInt(6) == 0) {
                final replacement = [for (var i = 0; i < random.nextInt(capacity + 3); i++) make()];
                list.replaceWith(replacement);
                model
                  ..clear()
                  ..addAll(replacement.length > capacity
                      ? replacement.sublist(replacement.length - capacity)
                      : replacement);
                did = 'replaceWith(${replacement.length})';
              }
          }
          final where = 'capacity $capacity, step $step, after $did:';
          expect(list.length, model.length, reason: '$where length');
          for (var i = 0; i < model.length; i++) {
            expect(identical(list[i], model[i]), isTrue, reason: '$where element $i is ${list[i]}, not ${model[i]}');
            expect(model[i].attached, isTrue, reason: '$where element $i knows it is in the list');
            expect(model[i].index, i, reason: '$where element $i knows its index');
            expect(identical(model[i].owner, list), isTrue, reason: '$where element $i knows its list');
          }
          final inList = model.toSet();
          for (final item in all) {
            if (!inList.contains(item)) {
              expect(item.attached, isFalse, reason: '$where $item left the list and knows it');
            }
          }
          // What is kept of those that left need not grow without end.
          if (all.length > 400) all.removeWhere((item) => !inList.contains(item));
        }
      }
    });
  });
}
