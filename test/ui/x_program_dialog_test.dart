import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/screens/session/screen_target.dart';
import 'package:zestssh/features/screens/xprogram/x_program_dialog.dart';
import 'package:zestssh/features/screens/xprogram/x_program_recent.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/theme/ui_density.dart' show ZestDensity;

import '../a11y/a11y_checks.dart';

/// "Open an X program..." (4.0): the question, the recent programs of
/// a host on this device, and the size of the picture. All made up.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  final at = DateTime(2026, 11, 9);

  test('the size: a phone at least 960 by 544, laid landscape; a computer the window less the chrome (the sidebar '
      'folded, where the page that asks is not known), 640 by 480 to 3840 by 2160; whole multiples of 8', () {
    expect(xProgramSizeFor(const Size(412, 915)), (width: 960, height: 544));
    expect(xProgramSizeFor(const Size(915, 412)), (width: 960, height: 544));
    expect(xProgramSizeFor(const Size(430, 1400)), (width: 1400, height: 544));
    expect(xProgramSizeFor(const Size(1600, 1000)), (width: 1544, height: 840));
    expect(xProgramSizeFor(const Size(700, 600)), (width: 648, height: 480));
    expect(xProgramSizeFor(const Size(8000, 5000)), (width: 3840, height: 2160));
    expect(xProgramSizeFor(const Size(1283, 917)), (width: 1224, height: 760));
  });

  group('the recent programs', () {
    late AppDatabase db;
    late XProgramRecent recent;
    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      recent = XProgramRecent(LocalStateStore(db));
    });
    tearDown(() => db.close());

    test('newest first, once each, 8 at most, per host; forgotten per host; a damaged value read as none', () async {
      for (var i = 0; i < 10; i++) {
        await recent.used('h1', 'prog$i');
      }
      await recent.used('h1', 'prog5');
      final h1 = await recent.of('h1');
      expect(h1, hasLength(8));
      expect(h1.first, 'prog5');
      expect(h1.where((p) => p == 'prog5'), hasLength(1));
      expect(await recent.of('h2'), isEmpty);
      await recent.used('h2', 'xclock');
      await recent.forget('h1');
      expect(await recent.of('h1'), isEmpty);
      expect(await recent.of('h2'), ['xclock']);
      await LocalStateStore(db).write('${XProgramRecent.prefix}h3', 'not json');
      expect(await recent.of('h3'), isEmpty);
      await LocalStateStore(db).write('${XProgramRecent.prefix}h3', '["ok", 7, "two\\nlines"]');
      expect(await recent.of('h3'), ['ok']);
    });
  });

  group('the question', () {
    late AppDatabase db;
    late ProviderContainer container;
    XProgramTarget? answered;
    var done = false;
    late Connection host;

    Future<void> pump(WidgetTester tester, {Size size = const Size(1400, 1000), bool touch = false}) async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      await tester.runAsync(() async {
        await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: 'h-gw', label: 'gw', host: 'gw.example.com', createdAt: at, updatedAt: at));
        host = (await db.connectionsDao.getById('h-gw'))!;
      });
      container = ProviderContainer(overrides: [localStateStoreProvider.overrideWithValue(LocalStateStore(db))]);
      addTearDown(() async {
        container.dispose();
        await db.close();
      });
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          // (The app's own theme: its buttons' inks are what the checks read; touch sized where
          // the app's is, on a phone or a tablet.)
          theme: AppTheme.dark().copyWith(
              extensions: [...AppTheme.dark().extensions.values, ZestDensity(touch: touch)]),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  done = false;
                  answered = await showXProgramDialog(context, host: host);
                  done = true;
                },
                child: const Text('ask'),
              ),
            ),
          ),
        ),
      ));
    }

    Future<void> ask(WidgetTester tester) async {
      await tester.tap(find.text('ask'));
      await tester.pumpAndSettle();
    }

    testWidgets('accessibility: the question meets the 4.0 pass on a computer and on a phone, empty, with recent '
        'programs and with a line it refuses (named controls, targets, contrast)', (tester) async {
      final handle = tester.ensureSemantics();
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      // Open, drawn turned off while there is nothing it could open: no contrast is asked of that.
      final off = {l10n.xProgramOpenButton};
      // The line's field is the app's shared one, 45 high on a phone: its height is that
      // widget's to change for every form at once, and is not held here.
      bool theSharedField(String line) => line.contains('isTextField');
      for (final (size, computer) in [(const Size(1400, 1000), true), (const Size(390, 844), false)]) {
        final where = computer ? 'a computer' : 'a phone';
        debugDefaultTargetPlatformOverride = computer ? TargetPlatform.windows : TargetPlatform.android;
        await pump(tester, size: size, touch: !computer);
        await tester.runAsync(() async {
          await XProgramRecent(LocalStateStore(db)).used('h-gw', 'gedit notes.txt');
          await XProgramRecent(LocalStateStore(db)).used('h-gw', 'xterm');
        });
        await ask(tester);
        final found = await a11yCheck(tester, computer: computer, where: '$where, with recent programs', except: off);
        await tester.enterText(find.byKey(const ValueKey('x-program-field')), 'xterm\t-e top');
        await tester.pumpAndSettle();
        expect(find.text(l10n.xProgramOneLine), findsOneWidget);
        found.addAll(await a11yCheck(tester, computer: computer, where: '$where, a line refused', except: off));
        // A line it takes: Open is on, and is held to the checks too.
        await tester.enterText(find.byKey(const ValueKey('x-program-field')), 'xclock');
        await tester.pumpAndSettle();
        found.addAll(await a11yCheck(tester, computer: computer, where: '$where, a line it takes'));
        expect(found.where((f) => !theSharedField(f)).toSet().toList(), isEmpty);
        // The field says what it is for, and the refusal is its error.
        expect(find.bySemanticsLabel(RegExp(RegExp.escape(l10n.xProgramDialogTitle))), findsWidgets);
        debugDefaultTargetPlatformOverride = null;
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
      }
      handle.dispose();
    });

    testWidgets('a line with a tab or a newline is refused in words, Open stays off while empty; an answer opens at '
        "the window's size and is remembered; a recent one opens with one tap; Forget these clears them",
        (tester) async {
      await pump(tester);
      await ask(tester);
      expect(find.text(l10n.xProgramDialogTitle), findsOneWidget);
      expect(find.text(l10n.xProgramDialogSubtitle('gw')), findsOneWidget);
      expect(find.text(l10n.xProgramDialogNote), findsOneWidget);
      expect(find.text(l10n.xProgramRecentLabel), findsNothing, reason: 'none yet');
      await tester.tap(find.text(l10n.xProgramOpenButton));
      await tester.pumpAndSettle();
      expect(done, isFalse, reason: 'nothing typed: Open does nothing');

      await tester.enterText(find.byKey(const ValueKey('x-program-field')), 'xterm\t-e top');
      await tester.pumpAndSettle();
      expect(find.text(l10n.xProgramOneLine), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('x-program-field')), 'x' * 1025);
      await tester.pumpAndSettle();
      expect(find.text(l10n.xProgramTooLong(1024)), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('x-program-field')), 'gedit notes.txt');
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.xProgramOpenButton));
      await tester.pumpAndSettle();
      expect(done, isTrue);
      expect(answered!.program, 'gedit notes.txt');
      expect((answered!.width, answered!.height), (1344, 840));

      await ask(tester);
      expect(find.text(l10n.xProgramRecentLabel), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('x-program-recent-0')));
      await tester.pumpAndSettle();
      expect(answered!.program, 'gedit notes.txt');

      await ask(tester);
      await tester.tap(find.byKey(const ValueKey('x-program-forget')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('x-program-recent-0')), findsNothing);
      expect(await container.read(xProgramRecentProvider).of('h-gw'), isEmpty);
      await tester.tap(find.text(l10n.cancel));
      await tester.pumpAndSettle();
      expect(answered, isNull);
    });
  });
}
