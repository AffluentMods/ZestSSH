import 'dart:ui' show Tristate;

import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/screens/sftp/widgets/sftp_locations_rail.dart';
import 'package:zestssh/ui/screens/sftp/widgets/transfer_queue_panel.dart';
import 'package:zestssh/utils/platform_utils.dart' show debugTouchLayout;

import 'a11y_checks.dart';

/// A computer's files dock: its places rail and its transfers to a screen
/// reader, a keyboard and a mouse (4.0 accessibility pass). Names here are
/// made up.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  // A mouse's least target (A11Y-BRIEF: 32 dp with a mouse).
  const mouseTargets = mouseTapTargetGuideline;

  void drawn(String name, Future<void> Function(WidgetTester tester) body) {
    testWidgets(name, (tester) async {
      debugTouchLayout = false;
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      L10nGlobal.update(en);
      final semantics = tester.ensureSemantics();
      try {
        await body(tester);
      } finally {
        semantics.dispose();
        debugTouchLayout = null;
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  Future<void> show(WidgetTester tester, Widget child, {Size size = const Size(900, 600)}) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Scaffold(body: child),
    ));
    await tester.pumpAndSettle();
  }

  Widget rail() => SizedBox(
        width: 240,
        height: 500,
        child: SftpLocationsRail(
          onCollapse: () {},
          groups: [
            RailGroup(
              label: 'web-01',
              paneSide: 1,
              onHeaderTap: (_) {},
              items: [
                RailItem(icon: LucideIcons.home, label: 'Home', pathHint: '/home/deploy', selected: true, onTap: () {}),
                RailItem(icon: LucideIcons.folder, label: 'releases', pathHint: '/srv/releases', onTap: () {}),
              ],
            ),
            RailGroup(
              label: 'This computer',
              paneSide: 2,
              items: [RailItem(icon: LucideIcons.monitor, label: 'Desktop', onTap: () {})],
            ),
          ],
        ),
      );

  drawn('the places rail: every control named, readable, 32 to a mouse', (tester) async {
    await show(tester, Align(alignment: Alignment.topLeft, child: rail()));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
    await expectLater(tester, meetsGuideline(mouseTargets));
    // The folder the pane shows is selected; the picker is a button.
    final home = tester.getSemantics(find.bySemanticsLabel(RegExp('^Home'))).getSemanticsData();
    expect(home.flagsCollection.isSelected, Tristate.isTrue);
    final picker = tester.getSemantics(find.bySemanticsLabel(RegExp('^web-01'))).getSemanticsData();
    expect(picker.flagsCollection.isButton, isTrue);
  });

  drawn("the places rail: the keyboard reaches the pane's picker and Enter opens it", (tester) async {
    var opened = 0;
    await show(
        tester,
        Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 240,
            height: 500,
            child: SftpLocationsRail(groups: [
              RailGroup(
                label: 'web-01',
                paneSide: 1,
                onHeaderTap: (_) => opened++,
                items: [RailItem(icon: LucideIcons.home, label: 'Home', onTap: () {})],
              ),
            ]),
          ),
        ));
    for (var i = 0; i < 10 && opened == 0; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final focus = FocusManager.instance.primaryFocus?.context;
      if (focus != null &&
          find.descendant(of: find.byElementPredicate((e) => e == focus), matching: find.text('web-01')).evaluate().isNotEmpty) {
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
      }
    }
    expect(opened, 1);
  });

  TransferItem item(String id, String name, TransferStatus status) => TransferItem(
        id: id,
        localPath: 'C:/demo/$name',
        remotePath: '/srv/demo/$name',
        fileName: name,
        direction: TransferDirection.upload,
        totalBytes: 2048,
      )..status = status;

  drawn('the transfers: every control named, readable, 32 to a mouse', (tester) async {
    await show(
        tester,
        Column(children: [
          const Expanded(child: SizedBox()),
          TransferQueuePanel(
            transfers: [
              item('u1', 'contracts.pdf', TransferStatus.active),
              item('u2', 'notes.txt', TransferStatus.failed),
              item('u3', 'deploy.log', TransferStatus.completed),
            ],
            onCancel: (_) {},
            onRetry: (_) {},
            onDismiss: (_) {},
            onClearCompleted: () {},
          ),
        ]));
    // Open the panel (its title bar is the first InkWell inside it).
    await tester.tap(find.descendant(of: find.byType(TransferQueuePanel), matching: find.byType(InkWell)).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
    await expectLater(tester, meetsGuideline(mouseTargets));
    // A row is one sentence: its name with its state.
    expect(find.bySemanticsLabel(RegExp('notes.txt')), findsOneWidget);
  });
}
