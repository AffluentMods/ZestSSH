import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/notifications/widgets/notification_toast_overlay.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/utils/platform_utils.dart' show debugTouchLayout;
import 'package:zestssh/ui/widgets/zest_a11y.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_mode_toggle.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';
import 'package:zestssh/ui/widgets/zest_status.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';

import 'a11y_checks.dart';

/// The shared controls every screen is built from, held to the 4.0
/// accessibility pass: a dialog names itself and its
/// heading, traps the keyboard and gives it back, closes by a labelled
/// button, Escape or a screen reader; its buttons are buttons with a ring;
/// an error in a field is said as it shows; a switch, a select and a few
/// segments say what they are for and what is chosen; a pointer's target is
/// 32 on a computer and 48 on a phone; nothing slides when less motion is
/// asked for; and a message stays to be read and is said aloud.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  setUp(() => AppColors.applyTheme(BuiltInThemes.getById('default_dark').colorScheme));

  Widget app(Widget home, {bool reduceMotion = false, bool screenReader = false, double textScale = 1}) => MaterialApp(
        theme: BuiltInThemes.getById('default_dark').toThemeData(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: reduceMotion,
            accessibleNavigation: screenReader,
            textScaler: TextScaler.linear(textScale),
          ),
          child: child!,
        ),
        home: Scaffold(body: home),
      );

  Widget opener(void Function(BuildContext context) open) =>
      Builder(builder: (context) => Center(child: TextButton(onPressed: () => open(context), child: const Text('open'))));

  Future<void> openDialog(WidgetTester tester, {bool reduceMotion = false, String? error}) async {
    await tester.pumpWidget(app(
      opener((context) => ZestDialogShell.showModal<void>(
            context,
            size: ZestModalSize.compact,
            tone: ZestDialogTone.info,
            title: 'Rename web-01',
            body: ZestTextField(controller: TextEditingController(text: 'web-01'), label: 'Name', errorText: error),
            primaryAction: (label: 'Rename', onPressed: () {}, icon: null),
            secondaryAction: (label: en.cancel, onPressed: () => Navigator.of(context).pop()),
          )),
      reduceMotion: reduceMotion,
    ));
    // The opener takes the keyboard first, as a button pressed by it would.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
  }

  group('a dialog', () {
    testWidgets('names itself by its title, a heading, in a route of its own', (tester) async {
      final handle = tester.ensureSemantics();
      await openDialog(tester);
      final title = tester.getSemantics(find.text('Rename web-01'));
      expect(title.flagsCollection.isHeader, isTrue);
      expect(title.flagsCollection.namesRoute, isTrue);
      expect(
          find.byWidgetPredicate((w) => w is Semantics && w.properties.scopesRoute == true), findsWidgets);
      handle.dispose();
    });

    testWidgets('its close is a button by name, a Tab stop with the ring, 32 square with a mouse', (tester) async {
      final handle = tester.ensureSemantics();
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await openDialog(tester);
      expect(
        tester.getSemantics(find.byKey(const ValueKey('zest-dialog-close'))),
        isSemantics(label: en.close, isButton: true, hasTapAction: true),
      );
      expect(tester.getSize(find.byKey(const ValueKey('zest-dialog-close'))), const Size(32, 32));
      // Shift+Tab from the field (which has the keyboard) comes to it.
      await tester.sendKeyEvent(LogicalKeyboardKey.shift);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(
          find.descendant(of: find.byKey(const ValueKey('zest-dialog-close')), matching: find.byKey(ZestFocusRing.ringKey)),
          findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Rename web-01'), findsNothing, reason: 'Enter on the close closed it');
      handle.dispose();
    });

    testWidgets('Tab stays in it, round and round; Escape closes it and the keyboard goes back to the opener',
        (tester) async {
      await openDialog(tester);
      final inDialog = find.byType(ZestDialogShell);
      for (var i = 0; i < 8; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final focused = FocusManager.instance.primaryFocus!.context!;
        expect(find.descendant(of: inDialog, matching: find.byElementPredicate((e) => e == focused)), findsOneWidget,
            reason: 'Tab $i left the dialog');
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Rename web-01'), findsNothing);
      final back = FocusManager.instance.primaryFocus!.context!;
      expect(find.ancestor(of: find.byElementPredicate((e) => e == back), matching: find.byType(TextButton)), findsOneWidget,
          reason: 'the keyboard is back on what opened it');
    });

    testWidgets('its buttons are buttons to a screen reader, and the keyboard on one shows the ring', (tester) async {
      final handle = tester.ensureSemantics();
      await openDialog(tester);
      expect(tester.getSemantics(find.text('Rename')), isSemantics(isButton: true, isEnabled: true, hasEnabledState: true));
      expect(tester.getSemantics(find.text(en.cancel)), isSemantics(isButton: true));
      // From the field: Tab to Cancel, then Rename.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(
          find.descendant(of: find.byKey(const ValueKey('zest-dialog-secondary')), matching: find.byKey(ZestFocusRing.ringKey)),
          findsOneWidget);
      handle.dispose();
    });

    testWidgets('its field is said by its name, and an error that comes up is said aloud', (tester) async {
      final handle = tester.ensureSemantics();
      var error = ValueNotifier<String?>(null);
      await tester.pumpWidget(app(ValueListenableBuilder<String?>(
        valueListenable: error,
        builder: (context, e, _) => ZestTextField(controller: TextEditingController(text: 'web-01'), label: 'Name', errorText: e),
      )));
      expect(tester.getSemantics(find.byType(EditableText)), isSemantics(label: 'Name', isTextField: true));
      tester.takeAnnouncements();
      error.value = 'A host is already called web-01';
      await tester.pump();
      expect(tester.takeAnnouncements(), contains(isAccessibilityAnnouncement('A host is already called web-01')));
      expect(tester.getSemantics(find.byType(EditableText)).getSemanticsData().validationResult,
          SemanticsValidationResult.invalid);
      error.dispose();
      error = ValueNotifier(null);
      handle.dispose();
    });

    testWidgets('with less motion asked for it is there at once, not grown and faded in', (tester) async {
      await tester.pumpWidget(app(
        opener((context) => ZestConfirmDialog.show(context, tone: ZestDialogTone.info, title: 'A question', body: 'Words.')),
        reduceMotion: true,
      ));
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump();
      final fades = tester.widgetList<Opacity>(
          find.ancestor(of: find.text('A question'), matching: find.byType(Opacity)));
      expect(fades.where((o) => o.opacity < 1), isEmpty);
    });

    testWidgets('on a phone its close and buttons are 48 high to a finger', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      debugTouchLayout = true;
      final handle = tester.ensureSemantics();
      try {
        tester.view.physicalSize = const Size(412, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(app(opener((context) => ZestConfirmDialog.show(context,
            tone: ZestDialogTone.destructive, title: 'Delete web-01?', body: 'It cannot be undone.', confirmLabel: 'Delete'))));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await expectA11y(tester, computer: false, where: 'a confirm on a phone', contrast: true);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        debugTouchLayout = null;
        handle.dispose();
      }
    });
  });

  group('controls', () {
    testWidgets('a switch in a row is said with the row\'s name, on or off, 48 square on a phone', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      debugTouchLayout = true;
      final handle = tester.ensureSemantics();
      try {
        await tester.pumpWidget(app(Center(
            child: ZestControlLabel(label: 'Bell', child: ZestSwitch(value: true, onChanged: (_) {})))));
        expect(tester.getSemantics(find.byType(ZestSwitch)), isSemantics(label: 'Bell', isToggled: true, hasToggledState: true));
        expect(tester.getSize(find.byType(ZestSwitch)), const Size(48, 48));
      } finally {
        debugDefaultTargetPlatformOverride = null;
        debugTouchLayout = null;
        handle.dispose();
      }
    });

    testWidgets('a select says what it chooses, what is chosen, that it is a button and whether it is open',
        (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(app(Center(
          child: ZestControlLabel(
              label: 'Theme',
              child: ZestSelect<int>(
                  value: 1, width: 200, items: const [ZestSelectItem(1, 'Ember'), ZestSelectItem(2, 'Daylight')], onChanged: (_) {})))));
      final node = find.descendant(
          of: find.byType(ZestSelect<int>), matching: find.byWidgetPredicate((w) => w is Semantics && w.properties.button == true));
      expect(tester.getSemantics(node), isSemantics(label: 'Theme', value: 'Ember', isButton: true, hasExpandedState: true, isExpanded: false));
      await tester.tap(find.byType(ZestSelect<int>));
      await tester.pumpAndSettle();
      expect(tester.getSemantics(node), isSemantics(label: 'Theme', isExpanded: true, hasExpandedState: true));
      handle.dispose();
    });

    testWidgets('a few segments: each a button, the chosen one said selected; at 200% text the bar grows', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(app(
          Center(
              child: ZestModeToggle(
            segments: const [ZestModeSegment(id: 'a', label: 'Simple'), ZestModeSegment(id: 'b', label: 'Advanced')],
            selectedId: 'b',
            onChanged: (_) {},
          )),
          textScale: 2));
      expect(tester.takeException(), isNull);
      expect(tester.getSemantics(find.text('Advanced')), isSemantics(isButton: true, isSelected: true, hasSelectedState: true, isInMutuallyExclusiveGroup: true));
      expect(tester.getSemantics(find.text('Simple')), isSemantics(isButton: true, isSelected: false, hasSelectedState: true));
      expect(tester.getSize(find.byType(ZestModeToggle)).height, greaterThan(30), reason: 'it was a fixed 30 that cut the words');
      handle.dispose();
    });

    testWidgets('a button is a button; on a phone a medium one is 48 high to a finger', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      debugTouchLayout = true;
      final handle = tester.ensureSemantics();
      try {
        await tester.pumpWidget(app(Center(child: ZestButton(label: 'Save', onPressed: () {}))));
        expect(tester.getSemantics(find.text('Save')), isSemantics(isButton: true, isEnabled: true, hasEnabledState: true));
        expect(tester.getSize(find.byType(ZestButton)).height, 48);
        await tester.pumpWidget(app(const Center(child: ZestButton(label: 'Save'))));
        expect(tester.getSemantics(find.text('Save')), isSemantics(isButton: true, isEnabled: false, hasEnabledState: true));
      } finally {
        debugDefaultTargetPlatformOverride = null;
        debugTouchLayout = null;
        handle.dispose();
      }
    });

    testWidgets('a status pill\'s words read on its own wash', (tester) async {
      await tester.pumpWidget(app(const Center(
          child: Column(children: [
        ZestStatusPill(kind: ZestStatusKind.neutral, label: 'This device'),
        ZestStatusPill(kind: ZestStatusKind.healthy, label: 'Connected'),
        ZestStatusPill(kind: ZestStatusKind.critical, label: 'Failed'),
      ]))));
      expect(a11yFailures(tester, computer: true), isEmpty);
    });
  });

  group('messages', () {
    tearDown(() => debugTopSnackBarOnPhone = null);

    test('a message stays long enough to read; one with something to press at least ten seconds', () {
      expect(toastDurationFor(isError: false, tappable: false, message: 'Copied'), kToastDuration);
      expect(toastDurationFor(isError: false, tappable: true, message: 'Host deleted'), const Duration(seconds: 10));
      final long = 'word ' * 30;
      expect(toastDurationFor(isError: false, tappable: false, message: long), greaterThan(const Duration(seconds: 8)));
      final notice = AppNotification(id: '1', title: 'Saved', severity: NotificationSeverity.info, actionLabel: 'Undo');
      expect(notice.effectiveDismissDuration, kNoticeWithActionStays);
      final plain = AppNotification(id: '2', title: 'Saved', severity: NotificationSeverity.info);
      expect(plain.effectiveDismissDuration, const Duration(seconds: 4));
      final error = AppNotification(id: '3', title: 'Failed', severity: NotificationSeverity.error);
      expect(error.effectiveDismissDuration, Duration.zero, reason: 'an error stays until closed');
    });

    testWidgets("a phone's message is said aloud as it shows, closes by a screen reader's dismiss, and with a "
        'screen reader on one with an action stays', (tester) async {
      debugTopSnackBarOnPhone = true;
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(app(
        opener((context) => showTopSnackBar(context, 'Host deleted', actionLabel: 'Undo', onAction: () {})),
        screenReader: true,
      ));
      tester.takeAnnouncements();
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump();
      expect(tester.takeAnnouncements(), contains(isAccessibilityAnnouncement('Host deleted')));
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      expect(find.text('Host deleted'), findsOneWidget, reason: 'it stays while a screen reader is on');
      final card = find.ancestor(of: find.text('Host deleted'), matching: find.byWidgetPredicate((w) => w is Semantics && w.properties.onDismiss != null));
      expect(card, findsOneWidget);
      tester.widget<Semantics>(card.first).properties.onDismiss!();
      await tester.pumpAndSettle();
      expect(find.text('Host deleted'), findsNothing);
      handle.dispose();
    });

    testWidgets("a phone's message with less motion asked for is there at once", (tester) async {
      debugTopSnackBarOnPhone = true;
      await tester.pumpWidget(app(opener((context) => showTopSnackBar(context, 'Copied')), reduceMotion: true));
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump();
      final slide = tester.widget<SlideTransition>(
          find.ancestor(of: find.text('Copied'), matching: find.byType(SlideTransition)).first);
      expect(slide.position.value, Offset.zero);
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(find.text('Copied'), findsNothing);
    });

    testWidgets("a computer's notice is said aloud, says its kind in words, and closes by a labelled 32 square button",
        (tester) async {
      final handle = tester.ensureSemantics();
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: app(const NotificationToastOverlay(child: SizedBox.expand())),
      ));
      tester.takeAnnouncements();
      container.read(notificationCenterProvider.notifier).error('Sync failed', body: 'The server did not answer.');
      await tester.pump();
      await tester.pump();
      expect(tester.takeAnnouncements(), contains(isAccessibilityAnnouncement('Sync failed. The server did not answer.')));
      await tester.pumpAndSettle();
      final close = find.byKey(const ValueKey('toast-close'));
      expect(tester.getSize(close), const Size(32, 32));
      expect(tester.getSemantics(close), isSemantics(label: en.close, isButton: true, hasTapAction: true));
      expect(find.bySemanticsLabel(en.a11yNoticeError), findsOneWidget);
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(find.text('Sync failed'), findsNothing);
      handle.dispose();
    });
  });
}
