import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Screenshots for checking the 3.0 UI offscreen, with the real fonts,
/// without running the app against anyone's data. Off unless asked for:
///
///   `flutter test --dart-define=ZEST_SHOTS=true test/visual/...`
///
/// Pictures land in build/shots/.
const shotsEnabled = bool.fromEnvironment('ZEST_SHOTS');

/// The app's fonts and icon fonts, so text is measured and drawn as in the
/// app (the test fonts are boxes).
Future<void> loadShotFonts() async {
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final f in files) {
      final bytes = File(f).readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
    await loader.load().timeout(const Duration(seconds: 30));
  }

  // The SDK running the test (the flutter tool sets FLUTTER_ROOT) has the Material icon font.
  final sdk = Platform.environment['FLUTTER_ROOT'] ?? 'C:/flutter';
  await family('GeistSans', [
    for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) 'assets/fonts/GeistSans-$w.ttf',
  ]);
  await family('JetBrainsMono', ['assets/fonts/JetBrainsMono-Regular.ttf', 'assets/fonts/JetBrainsMono-Bold.ttf']);
  await family('packages/lucide_icons/Lucide', ['packages/lucide_icons/assets/lucide.ttf']);
  await family('MaterialIcons', ['$sdk/bin/cache/artifacts/material_fonts/materialicons-regular.otf']);
}

/// The picture under the [RepaintBoundary] keyed [key], as build/shots/[name].png,
/// [pixelRatio] times its logical size.
Future<void> saveShot(WidgetTester tester, GlobalKey key, String name, {double pixelRatio = 1}) async {
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: pixelRatio);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final out = File('build/shots/$name.png')..createSync(recursive: true);
    out.writeAsBytesSync(data!.buffer.asUint8List());
  });
}

/// Real shadows for this test's pictures: the test binding draws them as
/// black outlines otherwise. [plainShadows] puts the binding's back before
/// the test ends, which it checks.
void realShadows() => debugDisableShadows = false;

void plainShadows() => debugDisableShadows = true;
