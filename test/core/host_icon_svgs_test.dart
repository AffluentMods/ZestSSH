import 'package:flutter_test/flutter_test.dart';
import 'package:vector_graphics_compiler/vector_graphics_compiler.dart';
import 'package:zestssh/core/data/host_icon_svgs.dart';

/// Every host-card icon must survive the same parser flutter_svg renders
/// with, and must actually paint something: a stroke-only line icon whose
/// `currentColor` failed to resolve, or a mark with every path `fill="none"`,
/// would silently show an empty tile.
void main() {
  const theme = SvgTheme(currentColor: Color(0xFFFFFFFF));

  bool paints(VectorInstructions vi) => vi.paints.any((p) =>
      (p.fill != null && (p.fill!.color.a) != 0) ||
      (p.stroke != null && (p.stroke!.color.a) != 0));

  test('every line icon parses without warnings and paints strokes', () {
    for (final entry in kHostLineIconSvgs.entries) {
      final vi = parseWithoutOptimizers(entry.value,
          key: entry.key, warningsAsErrors: true, theme: theme);
      expect(vi.paths, isNotEmpty, reason: entry.key);
      expect(paints(vi), isTrue, reason: '${entry.key} paints nothing');
      expect(vi.images, isEmpty, reason: entry.key);
    }
  });

  test('every brand mark parses without warnings and paints fills', () {
    for (final entry in kHostBrandIconSvgs.entries) {
      final vi = parseWithoutOptimizers(entry.value,
          key: entry.key, warningsAsErrors: true, theme: theme);
      expect(vi.paths, isNotEmpty, reason: entry.key);
      expect(paints(vi), isTrue, reason: '${entry.key} paints nothing');
      expect(vi.images, isEmpty, reason: entry.key);
    }
  });

  test('every icon sits in the 24x24 box', () {
    for (final entry in {...kHostLineIconSvgs, ...kHostBrandIconSvgs}.entries) {
      final vi = parseWithoutOptimizers(entry.value, theme: theme);
      expect(vi.width, 24, reason: entry.key);
      expect(vi.height, 24, reason: entry.key);
    }
  });

  // macOS was its name written out ("macOS", Simple Icons' wordmark): about
  // four pixels high in its box, too small to read on a host's card (a
  // design review). Its mark is the Apple, as it was before
  // the brand marks, filling the box as the others do.
  test("macOS's mark fills its box, not a line of small letters across it", () {
    final vi = parseWithoutOptimizers(kHostBrandIconSvgs['macos']!, theme: theme);
    final bounds = vi.paths.map((p) => p.bounds()).reduce((a, b) => a.expanded(b));
    expect(bounds.height, greaterThan(16));
    expect(bounds.width, greaterThan(12));
  });

  test('every line icon has a category', () {
    for (final id in kHostLineIconSvgs.keys) {
      expect(kHostLineIconCategories[id], isNotNull, reason: id);
    }
    expect(kHostLineIconCategories.values.toSet(), {
      'hardware', 'network', 'cloud', 'services', 'security', 'places', 'tags',
    });
  });
}
