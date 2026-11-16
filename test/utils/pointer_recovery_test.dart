import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/utils/pointer_recovery.dart';

/// Guards the stranded-pointer recovery the desktop window relies on.
///
/// The "window quits working after resize/fullscreen" bug is a pointer the
/// Win32 modal resize/maximize/fullscreen loop left flagged "down" in Flutter
/// (the up was swallowed), which wedges the gesture pipeline so all mouse input
/// dies. [PointerRecovery.recover] - now wired to the end-of-geometry window
/// events in WindowService - clears that phantom. These tests prove the
/// primitive: a down with no up is tracked and cleared, and a normal down+up
/// leaves nothing to cancel (so recovery never fires on legitimate input).
void main() {
  // _down is process-global; clear any residue between tests.
  setUp(() => PointerRecovery.recover());

  testWidgets('recover() cancels a stranded (down, no up) pointer',
      (tester) async {
    await tester.pumpWidget(
      PointerRecovery.wrap(child: const SizedBox.expand()),
    );

    // A pointer-down whose up never arrives - the modal-loop case.
    await tester.sendEventToBinding(
      const PointerDownEvent(pointer: 7, position: Offset(10, 10)),
    );
    await tester.pump();

    expect(PointerRecovery.recover(), 1,
        reason: 'the stranded pointer is found and cancelled');
    await tester.pump();
    expect(PointerRecovery.recover(), 0,
        reason: 'idempotent: nothing left to clear');
  });

  testWidgets('a normal down+up leaves nothing stranded', (tester) async {
    await tester.pumpWidget(
      PointerRecovery.wrap(child: const SizedBox.expand()),
    );

    await tester.tap(find.byType(SizedBox));
    await tester.pump();

    expect(PointerRecovery.recover(), 0,
        reason: 'a completed tap must not look like a stranded pointer');
  });

  testWidgets('recover() clears multiple stranded pointers', (tester) async {
    await tester.pumpWidget(
      PointerRecovery.wrap(child: const SizedBox.expand()),
    );

    await tester.sendEventToBinding(
      const PointerDownEvent(pointer: 1, position: Offset(5, 5)),
    );
    await tester.sendEventToBinding(
      const PointerDownEvent(pointer: 2, position: Offset(6, 6)),
    );
    await tester.pump();

    expect(PointerRecovery.recover(), 2);
    await tester.pump();
    expect(PointerRecovery.recover(), 0);
  });
}
