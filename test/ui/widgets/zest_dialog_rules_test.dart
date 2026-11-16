import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/file_manager.dart';

/// The dialog rules of 3.4, for every one
/// of the app's dialogs, held on the shell every dialog
/// is drawn with, so each keeps them at once:
///   1. a neutral dialog, colour only by meaning: a green tick for done, red
///      for destructive, amber only on a warning sentence (it painted a big
///      tile per tone, info orange and warning YELLOW, so an ordinary
///      question looked like an alarm);
///   2. one footer, Cancel then the main button, a side option bottom left
///      as a link (it was an outlined button);
///   3. a small 30 px icon, no lines under the header or over the footer (it
///      was a 38 px tile between two dividers);
///   6. paths in the system's style, the file name first.
void main() {
  Future<void> open(WidgetTester tester, Widget dialog) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showDialog<void>(context: context, builder: (_) => dialog),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  ZestDialogShell shell(ZestDialogTone tone, {String? tertiary}) => ZestDialogShell(
        tone: tone,
        title: 'Stop this run?',
        body: const Text('What has not started yet will not run.'),
        secondaryAction: (label: 'Cancel', onPressed: () {}),
        primaryAction: (label: 'Stop the run', icon: null, onPressed: () {}),
        tertiaryAction: tertiary == null ? null : (label: tertiary, onPressed: () {}),
      );

  Color iconColour(WidgetTester tester) => tester
      .widget<Icon>(find.descendant(of: find.byKey(const ValueKey('zest-dialog-icon')), matching: find.byType(Icon)))
      .color!;

  testWidgets('a small 30 px icon and no line under the header or over the footer', (tester) async {
    await open(tester, shell(ZestDialogTone.info));
    expect(tester.getSize(find.byKey(const ValueKey('zest-dialog-icon'))), const Size(30, 30));
    expect(find.descendant(of: find.byType(ZestDialogShell), matching: find.byType(Divider)), findsNothing);
  });

  for (final tone in [ZestDialogTone.warning, ZestDialogTone.info, ZestDialogTone.neutral]) {
    testWidgets('a ${tone.name} dialog is neutral: no yellow or orange tile, an orange main button', (tester) async {
      await open(tester, shell(tone));
      expect(iconColour(tester), AppColors.v3TextSecondary);
      final tile = tester.widget<Container>(find.byKey(const ValueKey('zest-dialog-icon')));
      final fill = (tile.decoration! as BoxDecoration).color!;
      for (final loud in [AppColors.v3Warning, AppColors.v3AccentPrimary]) {
        expect(fill.withValues(alpha: 1), isNot(loud), reason: '$tone');
      }
      expect(tone.buttonAccent, AppColors.v3AccentPrimary);
    });
  }

  testWidgets('red only for destructive, green only for done', (tester) async {
    await open(tester, shell(ZestDialogTone.destructive));
    expect(iconColour(tester), isNot(AppColors.v3TextSecondary));
    expect(ZestDialogTone.destructive.meaning, AppColors.v3Error);
    expect(ZestDialogTone.destructive.buttonAccent, AppColors.v3Error);
    expect(ZestDialogTone.success.meaning, AppColors.v3Success);
    expect(ZestDialogTone.warning.meaning, isNull);
  });

  testWidgets('one footer: the side option bottom left as a link, then Cancel, then the main button', (tester) async {
    await open(tester, shell(ZestDialogTone.neutral, tertiary: 'No password'));
    final side = tester.getRect(find.byKey(const ValueKey('zest-dialog-tertiary')));
    final cancel = tester.getRect(find.byKey(const ValueKey('zest-dialog-secondary')));
    final main = tester.getRect(find.byKey(const ValueKey('zest-dialog-primary')));
    expect(side.right, lessThan(cancel.left));
    expect(cancel.right, lessThan(main.left));
    expect(side.center.dy, moreOrLessEquals(cancel.center.dy, epsilon: 1));
    // A link: no box around it.
    final box = tester.widget<AnimatedContainer>(
        find.descendant(of: find.byKey(const ValueKey('zest-dialog-tertiary')), matching: find.byType(AnimatedContainer)));
    final border = (box.decoration! as BoxDecoration).border! as Border;
    expect(border.top.color, Colors.transparent);
  });

  testWidgets('a warning is one amber sentence inside, not the dialog', (tester) async {
    const sentence = 'Without a password, anyone who gets the file can read your SSH keys and passwords.';
    await open(
      tester,
      const ZestConfirmDialog(
        tone: ZestDialogTone.warning,
        title: 'Export a backup',
        body: 'A .zest file of everything that syncs.',
        warning: sentence,
        confirmLabel: 'Export unencrypted',
      ),
    );
    final callout = find.byKey(const ValueKey('zest-callout'));
    expect(callout, findsOneWidget);
    expect(find.descendant(of: callout, matching: find.text(sentence)), findsOneWidget);
    final box = tester.widget<Container>(callout).decoration! as BoxDecoration;
    expect(box.color!.withValues(alpha: 1), AppColors.v3Warning);
    // The frame stays neutral.
    expect(iconColour(tester), AppColors.v3TextSecondary);
  });

  group('a path in the system\'s style, the file name first', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('on Windows: every separator a backslash (a backup\'s path mixed them)', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      const mixed = r'C:\Users\alex\Documents/ZestSSH/backups/zestssh_backup_2026-11-05T13-01-22.zest';
      expect(systemPath(mixed), r'C:\Users\alex\Documents\ZestSSH\backups\zestssh_backup_2026-11-05T13-01-22.zest');
      final parts = splitSystemPath(mixed);
      expect(parts.name, 'zestssh_backup_2026-11-05T13-01-22.zest');
      expect(parts.folder, r'C:\Users\alex\Documents\ZestSSH\backups');
      expect(splitSystemPath(r'C:\notes.txt').folder, r'C:\');
    });

    test('elsewhere: as the system wrote it (a backslash is part of a name there)', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      const path = '/home/alex/Documents/ZestSSH/backups/odd\\name.zest';
      expect(systemPath(path), path);
      final parts = splitSystemPath(path);
      expect(parts.name, 'odd\\name.zest');
      expect(parts.folder, '/home/alex/Documents/ZestSSH/backups');
      expect(splitSystemPath('/notes.txt').folder, '/');
      expect(splitSystemPath('notes.txt'), (name: 'notes.txt', folder: ''));
    });
  });
}
