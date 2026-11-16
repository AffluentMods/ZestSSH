import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/utils/utf8_chunks.dart';

void main() {
  // Two, three and four bytes: e-acute, a CJK character and an emoji.
  const text = 'café 中文 🍊 done';
  final bytes = utf8.encode(text);

  test('a character cut in two anywhere is put together', () {
    for (var cut = 1; cut < bytes.length; cut++) {
      final chunks = Utf8Chunks();
      final shown = chunks.decode(bytes.sublist(0, cut)) + chunks.decode(bytes.sublist(cut));
      expect(shown, text, reason: 'cut after byte $cut');
    }
  });

  test('one byte at a time', () {
    final chunks = Utf8Chunks();
    final shown = StringBuffer();
    for (final b in bytes) {
      shown.write(chunks.decode([b]));
    }
    expect(shown.toString(), text);
  });

  test('what is no UTF-8 is a replacement character, never a throw', () {
    final chunks = Utf8Chunks();
    expect(chunks.decode([0x61, 0xff, 0x62]), 'a�b');
    expect(chunks.decode([0xC3]), '');
    expect(chunks.decode([0x41]), '�A', reason: 'a character cut short by another');
  });

  test('the end of the stream inside a character shows one replacement, and then starts again', () {
    final chunks = Utf8Chunks();
    expect(chunks.decode([0x61, 0xE4, 0xB8]), 'a');
    expect(chunks.finish(), '�');
    expect(chunks.decode(utf8.encode('中')), '中');
    expect(chunks.finish(), '');
  });
}
