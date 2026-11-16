import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/automation/widgets/triggers_view.dart';
import 'package:zestssh/features/notifications/widgets/notification_prefs_sheet.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/automation_api_key.dart';
import 'package:zestssh/providers/automation_provider.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/recording_reveal_gate.dart';
import 'package:zestssh/ui/widgets/zest_color_picker.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Rule 4 of the dialog rules (3.4): no dialog over a dialog. A follow-up of a
/// dialog shows in that dialog's place, and the dialog comes back as it was,
/// with what was typed in it, once the follow-up is answered. These tests hold the
/// four that still opened over their dialog: recording mode's question before
/// a secret shows (a password's eye in a prompt), the host for Create API key,
/// the reachability checks' question in the notification settings, and the
/// custom colour of a snippet category's or a host icon's colour. Each opened a
/// second dialog, with a second dimmed layer, over the first.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  /// The dialogs open: each has its own dimmed layer under it.
  int dialogsOpen(WidgetTester tester) => find.byType(ModalBarrier).evaluate().length - 1;

  Future<(BuildContext, ProviderContainer)> pump(WidgetTester tester,
      {bool recording = false, Widget? page, bool phone = false}) async {
    tester.view.physicalSize = phone ? const Size(390, 844) : const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({'automation_enabled': true});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() => tester.runAsync(db.close));
    final made = DateTime(2026, 1, 1);
    await tester.runAsync(() async {
      for (final label in ['web-01', 'db-primary']) {
        await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: 'h-$label', label: label, host: '$label.example.internal', createdAt: made, updatedAt: made));
      }
    });
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      recordingModeProvider.overrideWith((ref) => recording),
      isProProvider.overrideWith((ref) => _Pro()),
    ]);
    addTearDown(container.dispose);
    container.read(databaseSessionProvider.notifier).seed(db);
    await tester.runAsync(() => container.read(automationKeysProvider.notifier).ready);
    late BuildContext context;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Builder(builder: (ctx) {
          context = ctx;
          return Scaffold(body: page);
        }),
      ),
    ));
    await tester.pumpAndSettle();
    return (context, container);
  }

  /// A password in a dialog of the app's (a prompt's field, with its eye).
  Future<String?> passwordDialog(BuildContext context) => showZestInputDialog(
        context: context,
        title: 'Unlock web-01',
        fieldLabel: 'Password',
        obscureText: true,
        confirmLabel: 'Unlock',
      );

  bool obscured(WidgetTester tester) => tester.widget<EditableText>(find.byType(EditableText)).obscureText;

  group("recording mode's question before a password shows", () {
    for (final phone in [false, true]) {
      testWidgets('in the dialog it is asked from, which comes back as it was (${phone ? 'a phone' : 'a computer'})',
          (tester) async {
        debugDefaultTargetPlatformOverride = phone ? TargetPlatform.android : null;
        try {
          final (context, container) = await pump(tester, recording: true, phone: phone);
          String? typed = 'unanswered';
          unawaited(passwordDialog(context).then((v) => typed = v));
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(EditableText), 'made-up-pass');
          await tester.tap(find.byTooltip(l10n.zestDialogShow));
          await tester.pumpAndSettle();

          expect(find.byKey(const ValueKey('recording-reveal-gate')), findsOneWidget);
          expect(dialogsOpen(tester), 1, reason: 'one dialog, changed in place: none over it');
          expect(find.text('Unlock web-01'), findsNothing, reason: 'the prompt is not shown under it');

          // Cancel: the prompt as it was, the password typed and still hidden.
          await tester.tap(find.byKey(const ValueKey('recording-reveal-cancel')));
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('recording-reveal-gate')), findsNothing);
          expect(find.text('Unlock web-01'), findsOneWidget);
          expect(find.text('made-up-pass'), findsOneWidget);
          expect(obscured(tester), isTrue);
          expect(dialogsOpen(tester), 1);

          // Escape (or back) answers the question, not the prompt under it.
          await tester.tap(find.byTooltip(l10n.zestDialogShow));
          await tester.pumpAndSettle();
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('recording-reveal-gate')), findsNothing);
          expect(find.text('Unlock web-01'), findsOneWidget, reason: 'Escape closed the question only');
          await tester.tap(find.byTooltip(l10n.zestDialogShow));
          await tester.pumpAndSettle();
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('recording-reveal-gate')), findsNothing);
          expect(find.text('Unlock web-01'), findsOneWidget, reason: 'back closed the question only');
          expect(obscured(tester), isTrue);

          // Turning the mode off shows the password, in the prompt.
          await tester.tap(find.byTooltip(l10n.zestDialogShow));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('recording-reveal-turn-off')));
          await tester.pumpAndSettle();
          expect(obscured(tester), isFalse);
          expect(find.text('Unlock web-01'), findsOneWidget);
          expect(typed, 'unanswered', reason: 'the prompt is still open, unanswered');

          // The prompt's own answer is the prompt's.
          await tester.tap(find.byKey(const ValueKey('zest-dialog-primary')));
          await tester.pumpAndSettle();
          expect(typed, 'made-up-pass');
          expect(dialogsOpen(tester), 0);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }

    testWidgets('asked from a page (no dialog), it is a dialog of its own', (tester) async {
      final (context, _) = await pump(tester, recording: true);
      bool? go;
      unawaited(confirmRevealWhileRecording(context).then((v) => go = v));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('recording-reveal-gate')), findsOneWidget);
      expect(dialogsOpen(tester), 1);
      await tester.tap(find.byKey(const ValueKey('recording-reveal-cancel')));
      await tester.pumpAndSettle();
      expect(go, isFalse);
      expect(dialogsOpen(tester), 0);
    });
  });

  testWidgets("Create API key's host: chosen in the dialog's place, which comes back with what was typed",
      (tester) async {
    final (_, container) = await pump(tester, page: const TriggersView());
    await tester.tap(find.text(l10n.zestAutoCreateApiKey));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), 'deploy box');
    await tester.tap(find.text(l10n.zestAutoScopeSpecific));
    await tester.pumpAndSettle();

    expect(find.text(l10n.zestAutoScopeChoose), findsOneWidget);
    expect(dialogsOpen(tester), 1, reason: 'the host is chosen in the dialog, not in one over it');
    expect(find.text(l10n.triggersViewCreateKeyExplainer), findsNothing);

    // Escape goes back to Create API key, as it was.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text(l10n.triggersViewCreateKeyExplainer), findsOneWidget);
    expect(find.text('deploy box'), findsOneWidget);
    expect(dialogsOpen(tester), 1);

    // A host picked: back, the key scoped to it.
    await tester.tap(find.text(l10n.zestAutoScopeSpecific));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('host-picker-h-web-01')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.triggersViewCreateKeyExplainer), findsOneWidget);
    expect(find.text('web-01'), findsOneWidget, reason: 'the chip names the host');
    expect(find.text('deploy box'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('create-api-key-go')));
    await tester.pumpAndSettle();
    final AutomationApiKey made = container.read(automationKeysProvider).single;
    expect((made.label, made.scopeConnectionId), ('deploy box', 'h-web-01'));
  });

  testWidgets("the reachability checks' question: in the notification settings' place; Cancel goes back to them",
      (tester) async {
    final (context, container) = await pump(tester);
    showNotificationPrefsSheet(context);
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('settings-reach-checks'));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.text(l10n.reachChecksAskTitle), findsOneWidget);
    expect(dialogsOpen(tester), 1, reason: 'asked in the dialog, not in one over it');
    expect(find.text(l10n.notifPrefsTitle), findsNothing);

    await tester.tap(find.text(l10n.cancel));
    await tester.pumpAndSettle();
    expect(find.text(l10n.notifPrefsTitle), findsOneWidget, reason: 'the settings again, still open');
    expect(container.read(healthChecksEnabledProvider), isFalse);

    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.reachChecksAskTurnOn));
    await tester.pumpAndSettle();
    expect(container.read(healthChecksEnabledProvider), isTrue);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    expect(dialogsOpen(tester), 1);

    await tester.tap(find.byKey(const ValueKey('notif-prefs-done')));
    await tester.pumpAndSettle();
    expect(dialogsOpen(tester), 0);
  });

  group('a custom colour', () {
    Future<Color?> colourDialog(BuildContext context, ValueChanged<Color> picked) => showZestModal<Color>(
          context: context,
          size: ZestModalSize.compact,
          child: Builder(
            builder: (ctx) => ZestDialogShell(
              size: ZestModalSize.compact,
              tone: ZestDialogTone.neutral,
              title: 'Category colour',
              body: ZestColorPicker(presets: AppColors.labelPalette, selected: AppColors.labelPalette.first, onChanged: picked),
              secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(ctx).pop()),
            ),
          ),
        );

    testWidgets("in the dialog's place: Apply gives the colour to it, and it stays open", (tester) async {
      final (context, _) = await pump(tester);
      Color? picked;
      unawaited(colourDialog(context, (c) => picked = c));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('zest-color-picker-custom-entry')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('zest-custom-colour')), findsOneWidget);
      expect(find.text(l10n.zestColorPickerCustomTitle), findsOneWidget);
      expect(dialogsOpen(tester), 1, reason: 'in place, not a popover over the dialog');
      expect(find.text('Category colour'), findsNothing);
      // Its buttons are the footer's: Cancel and Apply, none in the body.
      expect(find.descendant(of: find.byKey(const ValueKey('zest-color-picker-apply')), matching: find.text(l10n.settingsApply)),
          findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);

      await tester.enterText(find.byKey(const ValueKey('zest-color-picker-hex-field')), '#3366CC');
      await tester.pump();
      // New over Current: the colour typed shows, the width of its column
      // (both halves had no width, and only their border showed, a line).
      final swatch = find.ancestor(of: find.text(l10n.zestColorPickerNew), matching: find.byType(Column)).first;
      final typed = find.descendant(
          of: swatch, matching: find.byWidgetPredicate((w) => w is ColoredBox && w.color == const Color(0xFF3366CC)));
      expect(typed, findsOneWidget);
      expect(tester.getSize(typed).width, greaterThan(100));
      await tester.tap(find.byKey(const ValueKey('zest-color-picker-apply')));
      await tester.pumpAndSettle();
      expect(picked, const Color(0xFF3366CC));
      expect(find.text('Category colour'), findsOneWidget, reason: 'its dialog again, still open');
      expect(dialogsOpen(tester), 1);

      // Cancel and Escape go back with nothing.
      picked = null;
      await tester.tap(find.byKey(const ValueKey('zest-color-picker-custom-entry')));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(picked, isNull);
      expect(find.text('Category colour'), findsOneWidget);
      expect(find.byKey(const ValueKey('zest-custom-colour')), findsNothing);
    });

    testWidgets('on a page (no dialog): a dialog of its own, the shell, Escape closes it', (tester) async {
      Color? picked;
      await pump(tester,
          page: Center(
            child: ZestColorPicker(
                presets: AppColors.labelPalette, selected: AppColors.labelPalette.first, onChanged: (c) => picked = c),
          ));
      await tester.tap(find.byKey(const ValueKey('zest-color-picker-custom-entry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('zest-custom-colour')), findsOneWidget);
      expect(find.byType(ZestDialogShell), findsOneWidget);
      expect(dialogsOpen(tester), 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(dialogsOpen(tester), 0);
      expect(picked, isNull);
    });
  });

  testWidgets('a question asked from a dialog is in its place, and a dialog closed right after it is not held',
      (tester) async {
    final (context, _) = await pump(tester);
    Object? closedWith = 'open';
    unawaited(showZestModal<String>(
      context: context,
      size: ZestModalSize.compact,
      child: Builder(
        builder: (ctx) => ZestDialogShell(
          size: ZestModalSize.compact,
          tone: ZestDialogTone.neutral,
          title: 'Edit snippet',
          body: const Text('Unsaved changes here'),
          primaryAction: (
            label: 'Close',
            icon: null,
            onPressed: () async {
              final discard = await ZestConfirmDialog.show(ctx,
                  tone: ZestDialogTone.destructive, title: 'Discard changes?', body: '', confirmLabel: 'Discard');
              if (discard == true && ctx.mounted) Navigator.of(ctx).pop('discarded');
            },
          ),
        ),
      ),
    ).then((v) => closedWith = v));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    expect(find.text('Unsaved changes here'), findsNothing);
    expect(dialogsOpen(tester), 1);
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(closedWith, 'discarded');
    expect(dialogsOpen(tester), 0);
  });
}
