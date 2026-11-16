import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// TerminalStyle.toTextStyle must request the calt/liga OpenType features ONLY
/// when ligatures are enabled - and never by default, so the legacy render is
/// byte-identical.
void main() {
  test('no fontFeatures by default (legacy render unchanged)', () {
    const style = TerminalStyle(fontFamily: 'FiraCode');
    expect(style.enableLigatures, isFalse);
    final ts = style.toTextStyle();
    expect(ts.fontFeatures, isNull);
  });

  test('enableLigatures requests calt + liga', () {
    const style = TerminalStyle(fontFamily: 'FiraCode', enableLigatures: true);
    final ts = style.toTextStyle();
    expect(ts.fontFeatures, isNotNull);
    expect(ts.fontFeatures, contains(const FontFeature.enable('calt')));
    expect(ts.fontFeatures, contains(const FontFeature.enable('liga')));
  });

  test('copyWith carries the flag both ways', () {
    const off = TerminalStyle(fontFamily: 'FiraCode');
    final on = off.copyWith(enableLigatures: true);
    expect(on.enableLigatures, isTrue);
    expect(on.toTextStyle().fontFeatures, isNotNull);
    expect(on.copyWith(enableLigatures: false).toTextStyle().fontFeatures,
        isNull);
  });
}
