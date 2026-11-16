import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:xterm/src/ui/painter.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/theme/terminal_fonts.dart';

import '../visual/shots_util.dart';

/// Nerd Font icons in the terminal (4.0): prompts and tools draw powerline
/// separators and file icons from Unicode's Private Use Area, which none of
/// the app's terminal fonts has. The bundled Symbols Nerd Font Mono is every
/// terminal's last fallback; its glyphs (one em wide) are drawn to fit one
/// cell. With the real fonts loaded, as the app has them.
///
/// The picture of a prompt: `flutter test --dart-define=ZEST_SHOTS=true
/// test/terminal/nerd_font_symbols_test.dart` writes build/shots/nerd_font_prompt.png.

const _fontPath = 'assets/fonts/SymbolsNerdFontMono-Regular.ttf';

/// The release font (v3.5.1) with its character map limited to the Private
/// Use Area by tool/nerd_font_pua_only.py.
const _fontSha256 = '9d08c540b19843ffad2340c82c412d5df971e364b469393acfc278d24619c610';

Future<void> _load(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    final bytes = File(f).readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
  }
  await loader.load();
}

Future<void> _loadFonts(WidgetTester tester) => tester.runAsync(() async {
      await _load('JetBrainsMono', ['assets/fonts/JetBrainsMono-Regular.ttf', 'assets/fonts/JetBrainsMono-Bold.ttf']);
      await _load('FiraCode', ['assets/fonts/FiraCode-Regular.ttf']);
      await _load(kNerdFontSymbolsFamily, [_fontPath]);
    });

/// Every code point the font's Unicode character maps (formats 4 and 12) point
/// at a glyph.
Set<int> _mappedCodePoints(Uint8List font) {
  final d = ByteData.sublistView(font);
  final numTables = d.getUint16(4);
  var cmap = -1;
  for (var i = 0; i < numTables; i++) {
    final rec = 12 + i * 16;
    if (String.fromCharCodes(font.sublist(rec, rec + 4)) == 'cmap') cmap = d.getUint32(rec + 8);
  }
  expect(cmap, greaterThan(0), reason: 'the font has no cmap table');
  final out = <int>{};
  final subtables = d.getUint16(cmap + 2);
  for (var i = 0; i < subtables; i++) {
    final platform = d.getUint16(cmap + 4 + i * 8);
    final offset = cmap + d.getUint32(cmap + 4 + i * 8 + 4);
    if (platform != 0 && platform != 3) continue;
    final format = d.getUint16(offset);
    if (format == 4) {
      final segX2 = d.getUint16(offset + 6);
      final ends = offset + 14;
      final starts = ends + segX2 + 2;
      final deltas = starts + segX2;
      final rangeOffsets = deltas + segX2;
      for (var s = 0; s < segX2 ~/ 2; s++) {
        final end = d.getUint16(ends + s * 2);
        final start = d.getUint16(starts + s * 2);
        final delta = d.getUint16(deltas + s * 2);
        final ro = d.getUint16(rangeOffsets + s * 2);
        for (var c = start; c <= end && c != 0xFFFF; c++) {
          int glyph;
          if (ro == 0) {
            glyph = (c + delta) & 0xFFFF;
          } else {
            final at = rangeOffsets + s * 2 + ro + (c - start) * 2;
            glyph = d.getUint16(at);
            if (glyph != 0) glyph = (glyph + delta) & 0xFFFF;
          }
          if (glyph != 0) out.add(c);
        }
      }
    } else if (format == 12) {
      final groups = d.getUint32(offset + 12);
      for (var g = 0; g < groups; g++) {
        final at = offset + 16 + g * 12;
        final start = d.getUint32(at);
        final end = d.getUint32(at + 4);
        final glyph = d.getUint32(at + 8);
        for (var c = start; c <= end; c++) {
          if (glyph + (c - start) != 0) out.add(c);
        }
      }
    }
  }
  return out;
}

bool _privateUse(int c) => (c >= 0xE000 && c <= 0xF8FF) || (c >= 0xF0000 && c <= 0x10FFFD);

const _theme = TerminalThemes.whiteOnBlack;
const _white = Color(0xFFFFFFFF);
const _black = Color(0xFF000000);

TerminalStyle _style(String family, {bool symbols = true}) => TerminalStyle(
      fontFamily: family,
      fontSize: 20,
      fontFamilyFallback: [
        for (final f in kTerminalFontFallback)
          if (symbols || f != kNerdFontSymbolsFamily) f,
      ],
    );

/// [text] on one terminal line, painted by the terminal's own painter, as raw
/// RGBA of [cols] cells by one row (nothing is drawn where there is no ink).
Future<({ByteData pixels, int width, int height, Size cell})> _paintLine(
  WidgetTester tester,
  TerminalStyle style,
  String text, {
  int cols = 12,
}) async {
  final terminal = Terminal()..write(text);
  final painter = TerminalPainter(theme: _theme, textStyle: style, textScaler: TextScaler.noScaling);
  final cell = painter.cellSize;
  final width = (cell.width * cols).ceil();
  final height = cell.height.ceil();
  final recorder = ui.PictureRecorder();
  painter.paintLine(Canvas(recorder), Offset.zero, terminal.lines[0]);
  final picture = recorder.endRecording();
  late ByteData pixels;
  await tester.runAsync(() async {
    final image = await picture.toImage(width, height);
    pixels = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    image.dispose();
  });
  return (pixels: pixels, width: width, height: height, cell: cell);
}

/// The box around every pixel with ink in it: (left, top, right, bottom),
/// right and bottom inclusive; null when nothing is drawn.
(int, int, int, int)? _ink(ByteData pixels, int width) {
  int? l, t, r, b;
  for (var i = 0; i < pixels.lengthInBytes; i += 4) {
    if (pixels.getUint8(i + 3) == 0) continue;
    final x = (i ~/ 4) % width, y = (i ~/ 4) ~/ width;
    l = l == null || x < l ? x : l;
    r = r == null || x > r ? x : r;
    t = t == null || y < t ? y : t;
    b = b == null || y > b ? y : b;
  }
  return l == null ? null : (l, t!, r!, b!);
}

Future<ByteData> _paragraphPixels(WidgetTester tester, TextStyle style, String text, {required Size size, Offset at = Offset.zero}) async {
  final builder = ui.ParagraphBuilder(style.getParagraphStyle())
    ..pushStyle(style.getTextStyle())
    ..addText(text);
  final paragraph = builder.build()..layout(const ui.ParagraphConstraints(width: double.infinity));
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawParagraph(paragraph, at);
  final picture = recorder.endRecording();
  late ByteData pixels;
  await tester.runAsync(() async {
    final image = await picture.toImage(size.width.ceil(), size.height.ceil());
    pixels = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    image.dispose();
  });
  return pixels;
}

bool _same(ByteData a, ByteData b) {
  if (a.lengthInBytes != b.lengthInBytes) return false;
  for (var i = 0; i < a.lengthInBytes; i += 4) {
    if (a.getUint32(i) != b.getUint32(i)) return false;
  }
  return true;
}

void main() {
  test('the bundled font is the release font limited to the Private Use Area, and the app lists it and its licences', () {
    final bytes = File(_fontPath).readAsBytesSync();
    expect(sha256.convert(bytes).toString(), _fontSha256,
        reason: 'make it with tool/nerd_font_pua_only.py from the v3.5.1 release font');

    final mapped = _mappedCodePoints(bytes);
    expect(mapped.length, 10610);
    expect(mapped.where((c) => !_privateUse(c)), isEmpty,
        reason: 'outside the Private Use Area the system fonts draw as before');
    // Powerline, Powerline Extra, Font Awesome, Material Design (plane 15),
    // Devicons, Seti, Octicons, Codicons.
    for (final c in [0xE0A0, 0xE0B0, 0xE0B2, 0xE0B4, 0xE0B6, 0xE0BC, 0xF07B, 0xF0214, 0xE718, 0xE5FF, 0xF418, 0xEA60]) {
      expect(mapped, contains(c), reason: 'U+${c.toRadixString(16).toUpperCase()}');
    }

    final pubspec = File('pubspec.yaml').readAsStringSync().replaceAll('\r\n', '\n');
    expect(pubspec, contains('    - family: $kNerdFontSymbolsFamily\n      fonts:\n        - asset: $_fontPath\n'));
    // Among the app's licence files (the app's own notice comes first).
    final licences = pubspec.substring(pubspec.indexOf('  licenses:\n'));
    expect(licences, contains('\n    - third_party/symbols-nerd-font/NOTICES.txt\n'));

    // Flutter adds the file to the app's NOTICES as it is: sections split by a
    // line of 80 hyphens (LF only), each its name, a blank line, the text.
    final notices = File('third_party/symbols-nerd-font/NOTICES.txt').readAsStringSync();
    expect(notices.contains('\r'), isFalse);
    final sections = notices.split('\n${'-' * 80}\n');
    expect(sections, hasLength(15));
    for (final s in sections) {
      expect(s.startsWith('Symbols Nerd Font\n\n'), isTrue, reason: s.substring(0, 80));
    }
    for (final words in [
      'Copyright (c) 2014 Ryan L McIntyre', // Nerd Fonts, MIT
      'Attribution 4.0 International', // Codicons, Font Awesome icons
      'Apache License', // Material Design Icons
      'SIL OPEN FONT LICENSE Version 1.1', // Pomicons, Weather Icons
      'Reserved Font Name Pomicons',
      'Copyright (c) 2023 GitHub Inc.', // Octicons
      'Copyright 2013 Kim Silkeb', // Powerline
      'This is free and unencumbered software released into the public domain.', // Font Logos
      'character map is limited to Unicode\'s Private', // what we changed
    ]) {
      expect(notices, contains(words));
    }
    expect(RegExp('[\u2013\u2014]').hasMatch(notices), isFalse);
  });

  test('every terminal falls back to the symbols font last', () {
    expect(kTerminalFontFallback.last, kNerdFontSymbolsFamily);
    // The detached window and a session replay draw with xterm's own style.
    expect(const TerminalStyle().fontFamilyFallback.last, kNerdFontSymbolsFamily);
    final container = ProviderContainer(overrides: [
      terminalFontFamilyProvider.overrideWith((ref) => TerminalFontFamily.firaCode),
      terminalFontSizeProvider.overrideWith((ref) => 14),
      terminalLigaturesProvider.overrideWith((ref) => false),
    ]);
    addTearDown(container.dispose);
    final style = container.read(terminalStyleProvider);
    expect(style.fontFamily, 'FiraCode');
    expect(style.fontFamilyFallback, kTerminalFontFallback);
    expect(style.toTextStyle().fontFamilyFallback, contains(kNerdFontSymbolsFamily));
  });

  testWidgets('a Private Use Area icon is drawn from the symbols font, not as a box', (tester) async {
    await _loadFonts(tester);
    const size = Size(40, 30);
    final fromFallback = await _paragraphPixels(tester, _style('JetBrainsMono').toTextStyle(color: _white), '', size: size);
    final fromSymbols = await _paragraphPixels(
        tester, const TextStyle(fontFamily: kNerdFontSymbolsFamily, fontSize: 20, height: 1.2, color: _white), '',
        size: size);
    final withoutSymbols =
        await _paragraphPixels(tester, _style('JetBrainsMono', symbols: false).toTextStyle(color: _white), '', size: size);
    expect(_ink(fromFallback, 40), isNotNull);
    expect(_same(fromFallback, fromSymbols), isTrue, reason: 'the folder icon comes from Symbols Nerd Font Mono');
    expect(_same(fromFallback, withoutSymbols), isFalse, reason: 'without the font it was another glyph (a box)');
  });

  testWidgets('icons and powerline separators take one cell and stay in it', (tester) async {
    await _loadFonts(tester);
    final style = _style('JetBrainsMono');

    // One cell each in the buffer (wcwidth 1 in the Private Use Area, plane 15 too).
    final terminal = Terminal()..write('abc\u{F0214}d');
    final line = terminal.lines[0];
    for (final (i, c) in [(0, 0x61), (1, 0xE0B0), (2, 0x62), (3, 0xF07B), (4, 0x63), (5, 0xF0214), (6, 0x64)]) {
      expect(line.getCodePoint(i), c);
      expect(line.getWidth(i), 1);
    }

    // The cell is measured on the terminal font alone: the symbols font in
    // the fallback list changes nothing of it.
    final painter = TerminalPainter(theme: _theme, textStyle: style, textScaler: TextScaler.noScaling);
    final without = TerminalPainter(theme: _theme, textStyle: _style('JetBrainsMono', symbols: false), textScaler: TextScaler.noScaling);
    expect(painter.cellSize, without.cellSize);
    expect(painter.cellSize.width, closeTo(12, 0.01)); // 0.6 em of 20
    final cw = painter.cellSize.width, ch = painter.cellSize.height;

    // The symbol font's glyph is one em wide: drawn as it is it would cover
    // most of the next cell.
    final builder = ui.ParagraphBuilder(style.toTextStyle().getParagraphStyle())
      ..pushStyle(style.toTextStyle().getTextStyle())
      ..addText('');
    final natural = builder.build()..layout(const ui.ParagraphConstraints(width: double.infinity));
    expect(natural.maxIntrinsicWidth, greaterThan(cw * 1.5));

    // An icon: scaled down whole, inside its cell (the third), centred.
    final icon = await _paintLine(tester, style, '  ');
    final (il, it, ir, ib) = _ink(icon.pixels, icon.width)!;
    expect(il, greaterThanOrEqualTo((2 * cw).floor() - 1));
    expect(ir, lessThanOrEqualTo((3 * cw).ceil()));
    expect(ir - il, greaterThan(cw * 0.6), reason: 'drawn at a size one can read');
    expect(((it + ib) / 2 - ch / 2).abs(), lessThan(3), reason: 'centred in the row');

    // A Material Design icon (plane 15) the same.
    final md = await _paintLine(tester, style, '  \u{F0214}');
    final (ml, _, mr, _) = _ink(md.pixels, md.width)!;
    expect(ml, greaterThanOrEqualTo((2 * cw).floor() - 1));
    expect(mr, lessThanOrEqualTo((3 * cw).ceil()));

    // A rounded separator JetBrains Mono does not have: over the whole cell,
    // top to bottom, so a prompt's segments meet it with no gap.
    for (final sep in ['', '', '']) {
      final p = await _paintLine(tester, style, '  $sep');
      final (pl, pt, pr, pb) = _ink(p.pixels, p.width)!;
      expect(pl, greaterThanOrEqualTo((2 * cw).floor() - 1), reason: sep.codeUnitAt(0).toRadixString(16));
      expect(pr, lessThanOrEqualTo((3 * cw).ceil()), reason: sep.codeUnitAt(0).toRadixString(16));
      expect(pt, lessThanOrEqualTo(1), reason: sep.codeUnitAt(0).toRadixString(16));
      expect(pb, greaterThanOrEqualTo(p.height - 2), reason: sep.codeUnitAt(0).toRadixString(16));
    }
  });

  testWidgets('a terminal font\'s own powerline arrow and every other character are drawn as before', (tester) async {
    await _loadFonts(tester);

    // Fira Code has U+E0B0 at its cell's width: drawn by the font, as a plain
    // paragraph at its cell draws it.
    final fira = _style('FiraCode');
    final painted = await _paintLine(tester, fira, '  ', cols: 4);
    final plain = await _paragraphPixels(tester, fira.toTextStyle(color: _theme.foreground), '',
        size: Size(painted.width.toDouble(), painted.height.toDouble()), at: Offset(2 * painted.cell.width, 0));
    expect(_same(painted.pixels, plain), isTrue);

    // Text with characters outside the Private Use Area the font once mapped
    // (U+276F, Starship's prompt sign, which Fira Code lacks): the same with
    // and without the symbols font.
    const text = 'demo@web ~/src ❯ ls ♥⚡';
    final withSymbols = await _paintLine(tester, fira, text, cols: 24);
    final withoutSymbols = await _paintLine(tester, _style('FiraCode', symbols: false), text, cols: 24);
    expect(_same(withSymbols.pixels, withoutSymbols.pixels), isTrue);
  });

  testWidgets('a prompt with powerline segments and file icons, as a picture', (tester) async {
    await _loadFonts(tester);
    if (shotsEnabled) await tester.runAsync(loadShotFonts);
    tester.view.physicalSize = const Size(840, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // Made-up demo prompt: a Starship-like line, then an eza-like listing.
    const esc = '\x1b';
    const orange = '$esc[48;2;255;122;26m$esc[38;2;20;20;20m';
    const blue = '$esc[48;2;36;114;200m$esc[38;2;255;255;255m';
    const reset = '$esc[0m';
    final terminal = Terminal(maxLines: 50)
      ..write('$esc[?25l')
      ..write('$orange  ~/src/demo $esc[38;2;255;122;26m$esc[48;2;36;114;200m$blue  main $reset$esc[38;2;36;114;200m$reset ls\r\n')
      ..write(' docs   app.ts   tool.py   README.md   Cargo.toml  \u{F0214} notes\r\n')
      ..write('$esc[38;2;255;122;26m$orange  12:04 $reset$esc[38;2;255;122;26m$reset ❯ git status\r\n');
    final key = GlobalKey();
    await tester.pumpWidget(WidgetsApp(
      color: _black,
      builder: (context, _) => ColoredBox(
        color: _black,
        child: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(
            key: key,
            child: SizedBox(
              width: 840,
              height: 120,
              child: TerminalView(terminal, theme: _theme, textStyle: _style('JetBrainsMono'), autofocus: false, hardwareKeyboardOnly: true),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    if (shotsEnabled) await saveShot(tester, key, 'nerd_font_prompt', pixelRatio: 2);
    // Each icon on the listing line kept its one cell: the names after them
    // are where the buffer has them.
    expect(terminal.lines[1].getCodePoint(2), 'd'.codeUnitAt(0));
    expect(terminal.lines[1].getCodePoint(10), 'a'.codeUnitAt(0));
    expect(terminal.lines[1].getCodePoint(56), 0xF0214);
  });
}
