import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// Renders a terminal line containing ligature pairs (!= => >= ->) with FiraCode
/// and proves the opt-in ligature paint path: the ON render differs from OFF
/// (the ligatures actually form), and both are saved to the scratchpad for a
/// human eyeball (on-grid, not corrupted). This exercises the real per-cell ->
/// run-batching switch in RenderTerminal.paintLine.

/// Where the rendered PNGs are dumped for a human eyeball: the folder named
/// by the ZEST_LIGATURE_OUT environment variable. Unset (the normal case) the
/// dump is skipped and the byte-comparison assertions (the actual test) still
/// run.
final String _outDir = Platform.environment['ZEST_LIGATURE_OUT'] ?? '';

void _dump(String name, Uint8List bytes) {
  try {
    if (_outDir.isEmpty) return;
    final dir = Directory(_outDir);
    if (dir.existsSync()) File('$_outDir/$name').writeAsBytesSync(bytes);
  } catch (_) {/* inspection aid only */}
}

/// Read synchronously and hand [FontLoader] an ALREADY-COMPLETED future - a
/// real async File read never resolves inside the test's fake-async zone, so
/// `loader.load()` would hang forever.
Future<ByteData> _loadFont(String path) {
  final bytes = File(path).readAsBytesSync();
  return Future.value(ByteData.view(Uint8List.fromList(bytes).buffer));
}

Future<Uint8List> _render(WidgetTester tester,
    {required bool ligatures, required String text}) async {
  final terminal = Terminal(maxLines: 40);
  terminal.write(text);
  final key = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        backgroundColor: const Color(0xFF1E1E1E),
        body: Center(
          child: RepaintBoundary(
            key: key,
            child: SizedBox(
              width: 520,
              height: 60,
              child: TerminalView(
                terminal,
                textStyle: TerminalStyle(
                  fontFamily: 'FiraCode',
                  fontSize: 18,
                  enableLigatures: ligatures,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  // A single deterministic frame: never pumpAndSettle - the terminal cursor
  // blink is a perpetual animation that never settles. Both on/off renders pump
  // the identical sequence, so the cursor phase matches and only the text
  // (ligatures) differs.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));

  final boundary =
      key.currentContext!.findRenderObject() as RenderRepaintBoundary;
  late Uint8List bytes;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2.0);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    bytes = data!.buffer.asUint8List();
  });
  return bytes;
}

void main() {
  testWidgets('ligatures ON changes rendering of ligature pairs; OFF matches '
      'legacy; both saved for inspection', (tester) async {
    final loader = FontLoader('FiraCode')
      ..addFont(_loadFont('assets/fonts/FiraCode-Regular.ttf'));
    await tester.runAsync(() => loader.load());

    const ligText = r'x=1; a != b => c >= d -> e |> f';
    final off = await _render(tester, ligatures: false, text: ligText);
    final on = await _render(tester, ligatures: true, text: ligText);

    _dump('ligatures_off.png', off);
    _dump('ligatures_on.png', on);

    // With a ligature font, enabling the feature must change what is drawn.
    expect(on, isNot(equals(off)),
        reason: 'ligatures ON must render differently from OFF');

    // A line with NO ligature-forming pairs must render IDENTICALLY on/off -
    // the run-batching path must not shift or corrupt ordinary text.
    const plain = r'the quick brown fox 12345';
    final plainOff = await _render(tester, ligatures: false, text: plain);
    final plainOn = await _render(tester, ligatures: true, text: plain);
    _dump('plain_on.png', plainOn);
    expect(plainOn, equals(plainOff),
        reason:
            'ligature run-batching must not change text with no ligatures');
  });
}
