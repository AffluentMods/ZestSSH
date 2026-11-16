import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/ui/screens/desktop/widgets/desktop_status_bar.dart';

import '../../video/scenes_desktop.dart';
import '../../video/video_util.dart';
import '../../video/video_world.dart';

/// The desktop app at the narrow end of its window sizes (its smallest is
/// 800 wide), with the real fonts and the demo fleet: two sessions open,
/// one in front and then the Hosts page. Nothing overflows; the status bar
/// leaves out the readouts that do not fit, whole, instead of drawing past
/// its edge (8.5 px at 840 wide, 48 at 800, with a session in front).
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  stubPlugins();

  for (final width in [800.0, 840.0, 900.0]) {
    testWidgets('$width wide: a session in front, then the Hosts page', (tester) async {
      final size = Size(width, 700);
      final world = await pumpDesktop(tester, Rig(tester, StageLayout.bare(size, size)));
      world.sessions.open('web-02');
      final id = world.sessions.open('db-primary');
      await settleApp(tester);
      showSession(world, id);
      await settleApp(tester);
      expect(tester.takeException(), isNull, reason: 'a session in front');
      final bar = find.byType(DesktopStatusBar);
      final barRect = tester.getRect(bar);
      // The session count stays, inside the bar.
      final count = find.descendant(of: bar, matching: find.byKey(const ValueKey('status-sessions')));
      expect(count, findsOneWidget);
      expect(barRect.contains(tester.getCenter(count)), isTrue);
      // The focused session's user@host, whole or shortened, inside the bar.
      final userHost = find.byKey(const ValueKey('status-user-host'));
      expect(userHost, findsOneWidget);
      expect(tester.getRect(userHost).right, lessThanOrEqualTo(barRect.right));

      await showNav(tester, world, NavSection.hosts, label: 'Hosts');
      expect(tester.takeException(), isNull, reason: 'the Hosts page');
      expect(hostCard('web-01'), findsOneWidget);
      await tearDownWorld(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  }
}
