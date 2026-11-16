import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/app.dart' show rebuildEverything;

/// After a change of theme, what reads the colours directly (not through the
/// context) is built again too, where it stays open across the change by a
/// global key (Settings came out half light, half
/// dark after a change of theme, until it was closed and opened again).
Color _shown = Colors.black;

class _ReadsDirectly extends StatelessWidget {
  const _ReadsDirectly();

  @override
  Widget build(BuildContext context) => ColoredBox(key: const ValueKey('box'), color: _shown, child: const SizedBox(width: 10, height: 10));
}

void main() {
  testWidgets('every widget on screen is built again, a const one kept by a global key too', (tester) async {
    final kept = GlobalKey();
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: KeyedSubtree(key: kept, child: const _ReadsDirectly()),
    ));
    ColoredBox box() => tester.widget<ColoredBox>(find.byKey(const ValueKey('box')));
    expect(box().color, Colors.black);
    _shown = Colors.white;
    await tester.pump();
    expect(box().color, Colors.black, reason: 'nothing asked it to build again');
    rebuildEverything();
    await tester.pump();
    expect(box().color, Colors.white);
  });
}
