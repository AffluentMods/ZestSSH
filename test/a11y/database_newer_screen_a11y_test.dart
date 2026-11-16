import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart' show DatabaseNewerThanApp;
import 'package:zestssh/ui/screens/error/database_error_screen.dart';
import 'package:zestssh/utils/platform_utils.dart' show debugTouchLayout;

import '../visual/shots_util.dart' show loadShotFonts;
import 'a11y_checks.dart';

/// The start screen for data from a newer ZestSSH
/// held to the 4.0 accessibility pass's checks: every control named, a
/// mouse's 32 on a computer and a finger's 48 on a phone, and every word
/// reading on what it is drawn on.
void main() {
  for (final computer in [true, false]) {
    testWidgets('on a ${computer ? 'computer' : 'phone'}', (tester) async {
      await tester.runAsync(loadShotFonts);
      debugTouchLayout = !computer;
      addTearDown(() => debugTouchLayout = null);
      tester.view.physicalSize = computer ? const Size(1200, 1000) : const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(DatabaseErrorApp(
        report: 'What: This data is from a newer ZestSSH\nError: ${const DatabaseNewerThanApp(56, 55)}',
        databasePath: 'C:/Users/demo/AppData/Roaming/ZestSSH/zestssh.db',
        onRetry: () {},
        onReset: null,
        newerData: true,
        launch: (_) async => true,
        reveal: (_) async {},
      ));
      await settleA11y(tester);
      await expectA11y(tester, computer: computer, where: 'newer data screen');
    });
  }
}
