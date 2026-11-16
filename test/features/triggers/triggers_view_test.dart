import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/triggers/alert_presets.dart';
import 'package:zestssh/features/triggers/trigger_runtime.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/trigger_providers.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/desktop/widgets/triggers_view.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/ui/widgets/zest_detail_scaffold.dart';
import 'package:zestssh/ui/widgets/zest_pane_footer.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';

import '../../visual/shots_util.dart';

/// The desktop Triggers screen is the two-pane shell (card grid + a persistent
/// editor pane that sits in "New trigger" by default). This pumps it with a
/// trigger and asserts the card and the New pane both render.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TerminalTrigger trig() => TerminalTrigger(
        id: 't1',
        name: 'Error',
        pattern: r'(?i)\b(error|failed)\b',
        caseSensitive: false,
        notify: true,
        highlight: true,
        highlightColor: 0xFFEF4444,
        playSound: false,
        connectionId: null,
        enabled: true,
        sortOrder: 0,
        createdAt: DateTime(2026, 3, 14),
      );

  testWidgets('renders the card grid and the persistent New trigger pane',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(ProviderScope(
      overrides: [
        // Cards and the editor header route names/patterns through the
        // recording-mode scan, which watches the settings (prefs-backed).
        sharedPreferencesProvider.overrideWithValue(prefs),
        // The card's telemetry label reads triggerRuntimeProvider. Use a no-DAO
        // test runtime so no live database stream keeps pumpAndSettle from ever
        // settling (a real DAO watch stream never goes idle).
        triggerRuntimeProvider.overrideWith((ref) {
          final rt = TriggerRuntime.forTesting(ref);
          ref.onDispose(rt.dispose);
          return rt;
        }),
        triggersProvider.overrideWith((ref) => Stream.value([trig()])),
        triggerScopeConnectionsProvider
            .overrideWith((ref) => Stream.value(const <Connection>[])),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: TriggersView()),
      ),
    ));
    await tester.pumpAndSettle();

    final l10n =
        AppLocalizations.of(tester.element(find.byType(TriggersView)))!;

    // The card is in the list, showing its name and pattern.
    expect(find.text('Error'), findsOneWidget);
    expect(find.textContaining('error|failed'), findsWidgets);
    // The detail pane is mounted in New alert (its title), with Save alert in
    // its footer.
    expect(find.text(l10n.trgNewTrigger), findsWidgets);
    expect(find.descendant(of: find.byType(ZestDetailScaffold), matching: find.text(l10n.trgNewTrigger)), findsOneWidget);
    expect(find.descendant(of: find.byType(ZestDetailScaffold), matching: find.text(l10n.alertsSaveAlert)), findsOneWidget);
  });

  // The page as designed, named Alerts:
  // a trigger notifies, plays a sound and highlights, nothing else.
  group('Alerts', () {
    late _Crud crud;

    Future<AppLocalizations> pump(
      WidgetTester tester,
      List<TerminalTrigger> rows, {
      Size size = const Size(1440, 1000),
      String locale = 'en',
      StreamController<List<TerminalTrigger>>? stream,
      bool realFont = false,
    }) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      crud = _Crud();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          triggerRuntimeProvider.overrideWith((ref) {
            final rt = TriggerRuntime.forTesting(ref);
            ref.onDispose(rt.dispose);
            return rt;
          }),
          triggersProvider.overrideWith((ref) => stream?.stream ?? Stream.value(rows)),
          triggerScopeConnectionsProvider.overrideWith((ref) => Stream.value(const <Connection>[])),
          triggerCrudProvider.overrideWithValue(crud),
        ],
        child: MaterialApp(
          theme: realFont ? BuiltInThemes.getById('graphite').toThemeData() : null,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale(locale),
          home: const Scaffold(body: TriggersView()),
        ),
      ));
      await tester.pumpAndSettle();
      return lookupAppLocalizations(Locale(locale));
    }

    /// What the notification center was told, in this test's scope.
    List<String> saidBy(WidgetTester tester) {
      final c = ProviderScope.containerOf(tester.element(find.byType(TriggersView)), listen: false);
      return [for (final n in c.read(notificationCenterProvider).history) n.title];
    }

    testWidgets('the head counts all, on and off, and filters by them', (tester) async {
      final off = TerminalTrigger(
        id: 't2',
        name: 'Warning',
        pattern: r'\bwarn(ing)?\b',
        caseSensitive: false,
        notify: true,
        highlight: false,
        highlightColor: null,
        playSound: true,
        connectionId: null,
        enabled: false,
        sortOrder: 1,
        createdAt: DateTime(2026, 3, 14),
      );
      final l10n = await pump(tester, [trig(), off]);
      expect(find.text(l10n.trgTitle), findsOneWidget);
      expect(find.text('Alerts'), findsOneWidget);
      expect(find.text(l10n.alertsWatchLine), findsOneWidget);
      expect(find.text(l10n.alertsFilterAll(2)), findsOneWidget);
      expect(find.text(l10n.alertsFilterOn(1)), findsOneWidget);
      expect(find.text(l10n.alertsFilterOff(1)), findsOneWidget);
      // What each does, as chips.
      expect(find.text(l10n.alertsChipHighlight), findsOneWidget);
      expect(find.text(l10n.alertsChipSound), findsOneWidget);
      await tester.tap(find.text(l10n.alertsFilterOff(1)));
      await tester.pumpAndSettle();
      expect(find.text('Warning'), findsOneWidget);
      expect(find.text('Error'), findsNothing);
      await tester.tap(find.text(l10n.alertsFilterOn(1)));
      await tester.pumpAndSettle();
      expect(find.text('Error'), findsOneWidget);
      expect(find.text('Warning'), findsNothing);
    });

    testWidgets('Simple: a preset fills the pattern, the test line says whether it matches, Save keeps it',
        (tester) async {
      final l10n = await pump(tester, const []);
      // A new alert starts from Errors, named after it, with an example line
      // that matches.
      expect(find.text(l10n.alertsMatchesLinesLike), findsOneWidget);
      expect(find.text(l10n.alertsTestMatches), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('alert-preset-buildFinished')));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, l10n.alertsPresetBuildFinished), findsOneWidget, reason: 'the name follows');
      await tester.enterText(find.byKey(const ValueKey('alert-test-line')), 'npm ERR! missing script');
      await tester.pumpAndSettle();
      expect(find.text(l10n.alertsTestNoMatch), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('alert-test-line')), 'Build finished in 42.1s');
      await tester.pumpAndSettle();
      expect(find.text(l10n.alertsTestMatches), findsOneWidget, reason: 'upper or lower case alike');
      await tester.tap(find.byKey(const ValueKey('alert-sound')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.alertsSaveAlert));
      await tester.pumpAndSettle();
      expect(crud.created, hasLength(1));
      final saved = crud.created.single;
      expect(saved['name'], l10n.alertsPresetBuildFinished);
      expect(saved['pattern'], AlertPreset.buildFinished.pattern);
      expect(saved['caseSensitive'], isFalse);
      expect(saved['notify'], isTrue);
      expect(saved['playSound'], isTrue);
      await tester.pump(const Duration(seconds: 4)); // The Saved toast goes.
    });

    testWidgets('Simple: your own text is watched for as it is written', (tester) async {
      final l10n = await pump(tester, const []);
      await tester.tap(find.byKey(const ValueKey('alert-preset-ownText')));
      await tester.pumpAndSettle();
      await tester.enterText(find.descendant(of: find.byKey(const ValueKey('alert-own-text')), matching: find.byType(TextField)),
          'Out of memory (heap)');
      // The name is the person's to give: the preset named none.
      await tester.enterText(
          find.descendant(of: find.byKey(const ValueKey('alert-name')), matching: find.byType(TextField)), 'Out of memory');
      await tester.enterText(find.byKey(const ValueKey('alert-test-line')), 'java: out of memory (heap) at 3:02');
      await tester.pumpAndSettle();
      expect(find.text(l10n.alertsTestMatches), findsOneWidget);
      await tester.tap(find.text(l10n.alertsSaveAlert));
      await tester.pumpAndSettle();
      expect(crud.created.single['pattern'], r'Out of memory \(heap\)');
      await tester.pump(const Duration(seconds: 4)); // The Saved toast goes.
    });

    // Saving failed with no error, and changing the colour did
    // nothing. A save reset the pane from the row of before the save.
    group('Save', () {
      setUp(() => NotificationCenter.debugToastsDrawn = true);
      tearDown(() => NotificationCenter.debugToastsDrawn = null);

      bool dotShown(AppLocalizations l10n) => find.byTooltip(l10n.zestDetailUnsaved).evaluate().isNotEmpty;

      testWidgets('keeps the colour just picked, says so, and the dot goes out, though the list has not heard yet',
          (tester) async {
        final l10n = await pump(tester, [trig()]);
        await tester.tap(find.text('Error'));
        await tester.pumpAndSettle();
        expect(dotShown(l10n), isFalse);
        final green = find.byKey(ValueKey('alert-colour-${0xFF22C55E.toRadixString(16)}'));
        await tester.ensureVisible(green);
        await tester.pumpAndSettle();
        await tester.tap(green);
        await tester.pumpAndSettle();
        expect(dotShown(l10n), isTrue);
        await tester.tap(find.text(l10n.alertsSaveAlert));
        await tester.pump();
        await tester.pump();
        expect(crud.updated.single['highlightColor'], 0xFF22C55E);
        expect(dotShown(l10n), isFalse, reason: 'saved: the dot clears');
        expect(saidBy(tester).any((m) => m.contains('Error')), isTrue, reason: 'the Saved toast');
        // The colour stays picked: the row the list still has says red.
        final picked = tester.widget<Container>(find.descendant(of: green, matching: find.byType(Container)).first);
        expect((picked.decoration! as BoxDecoration).border, isNotNull);
        await tester.tap(find.text(l10n.alertsSaveAlert), warnIfMissed: false);
        await tester.pump();
        expect(crud.updated, hasLength(1), reason: 'nothing to save again');
        await tester.pump(const Duration(seconds: 4)); // The Saved toast goes.
      });

      testWidgets('a new alert stays open as itself, and a second save changes it instead of making another',
          (tester) async {
        final l10n = await pump(tester, const []);
        await tester.tap(find.text(l10n.alertsSaveAlert));
        await tester.pump();
        await tester.pump();
        expect(crud.created, hasLength(1));
        expect(dotShown(l10n), isFalse);
        expect(find.descendant(of: find.byType(ZestDetailScaffold), matching: find.text(l10n.trgNewTrigger)), findsNothing,
            reason: 'not back to a new one while the list has not heard');
        await tester.tap(find.byKey(const ValueKey('alert-sound')));
        await tester.pumpAndSettle();
        await tester.tap(find.text(l10n.alertsSaveAlert));
        await tester.pump();
        await tester.pump();
        expect(crud.created, hasLength(1), reason: 'not a second alert');
        expect(crud.updated.single['id'], 'new-1');
        expect(crud.updated.single['playSound'], isTrue);
        await tester.pump(const Duration(seconds: 4)); // The Saved toast goes.
      });

      testWidgets('a save that fails says what happened and what to do, with its code and Copy details',
          (tester) async {
        final l10n = await pump(tester, [trig()]);
        crud.fail = true;
        await tester.tap(find.text('Error'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('alert-sound')));
        await tester.pumpAndSettle();
        await tester.tap(find.text(l10n.alertsSaveAlert));
        await tester.pump();
        await tester.pump();
        final notice = find.byKey(const ValueKey('alert-save-failed'));
        expect(notice, findsOneWidget);
        expect(find.descendant(of: notice, matching: find.textContaining(ErrorCodes.localSaveFailed.code)), findsOneWidget);
        expect(find.descendant(of: notice, matching: find.byType(CopyDetailsButton)), findsOneWidget);
        expect(dotShown(l10n), isTrue, reason: 'still not saved');
        expect(saidBy(tester), isEmpty, reason: 'no Saved toast');
        // Saved at the next try, the notice goes.
        crud.fail = false;
        await tester.tap(find.text(l10n.alertsSaveAlert));
        await tester.pump();
        await tester.pump();
        expect(notice, findsNothing);
        expect(dotShown(l10n), isFalse);
        await tester.pump(const Duration(seconds: 4)); // The Saved toast goes.
      });

      testWidgets('a selection deleted elsewhere still falls back to a new alert', (tester) async {
        final rows = StreamController<List<TerminalTrigger>>.broadcast();
        addTearDown(rows.close);
        final l10n = await pump(tester, [trig()], stream: rows);
        rows.add([trig()]);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Error'));
        await tester.pumpAndSettle();
        rows.add(const []);
        await tester.pumpAndSettle();
        expect(find.descendant(of: find.byType(ZestDetailScaffold), matching: find.text(l10n.trgNewTrigger)), findsOneWidget);
      });
    });

    // The panel's right edge was cut off. Delete at the
    // left, Cancel and Save at the right, at every window the two panes stand in.
    group('the panel stays within the window', () {
      for (final width in [1000.0, 1100.0, 1240.0, 1440.0, 1920.0]) {
        for (final locale in ['en', 'de']) {
          testWidgets('$locale at $width', (tester) async {
            // The real font: the test's own is boxes, far wider than words.
            await tester.runAsync(loadShotFonts);
            final l10n = await pump(tester, [trig()], size: Size(width, 900), locale: locale, realFont: true);
            await tester.tap(find.text('Error'));
            await tester.pumpAndSettle();
            final pane = tester.getRect(find.byType(ZestDetailScaffold));
            expect(pane.right, lessThanOrEqualTo(width));
            expect(pane.width, greaterThanOrEqualTo(ZestSizing.detailPaneMinWidth - 1));
            for (final s in find.descendant(of: find.byType(ZestDetailScaffold), matching: find.byType(ZestSwitch)).evaluate()) {
              expect(tester.getRect(find.byWidget(s.widget)).right, lessThanOrEqualTo(pane.right - 8));
            }
            final close = tester.getRect(find.descendant(of: find.byType(ZestDetailScaffold), matching: find.byIcon(LucideIcons.x)));
            expect(close.right, lessThanOrEqualTo(pane.right));
            final delete = tester.getRect(find.text(l10n.delete).last);
            final cancel = tester.getRect(find.descendant(of: find.byType(ZestPaneFooter), matching: find.text(l10n.zestCommonCancel)));
            final save = tester.getRect(find.text(l10n.alertsSaveAlert));
            expect(delete.right, lessThan(cancel.left), reason: 'Delete at the left');
            expect(cancel.right, lessThan(save.left), reason: 'Cancel then Save, on one line');
            expect(cancel.top, save.top);
            expect(save.right, lessThanOrEqualTo(pane.right));
          });
        }
      }
    });

    testWidgets('an alert of a regular expression of its own opens in Regex, and Edit as regex keeps the pattern',
        (tester) async {
      final l10n = await pump(tester, [trig()]);
      await tester.tap(find.text('Error'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('alert-pattern')), findsOneWidget);
      expect(find.widgetWithText(TextField, r'(?i)\b(error|failed)\b'), findsOneWidget);
      // A new one, Simple, switched to Regex.
      await tester.tap(find.byKey(const ValueKey('alerts-new')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('alert-edit-as-regex')));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, AlertPreset.errors.pattern), findsOneWidget);
      expect(find.text(l10n.alertsModeRegex), findsOneWidget);
      // The one switch for this, the same way round in both forms.
      expect(find.byKey(const ValueKey('alert-any-case')), findsOneWidget);
      expect(find.text(l10n.alertsAnyCase), findsOneWidget);
      expect(find.text(l10n.trgCaseSensitive), findsNothing);
    });
  });
}

/// Keeps what the page asks to create.
class _Crud implements TriggerCrud {
  final created = <Map<String, Object?>>[];
  final updated = <Map<String, Object?>>[];

  /// Every save fails, as a full disk does.
  bool fail = false;

  @override
  Future<String> create({
    required String name,
    required String pattern,
    bool caseSensitive = false,
    bool notify = true,
    bool highlight = false,
    int? highlightColor,
    bool playSound = false,
    String? connectionId,
    bool enabled = true,
  }) async {
    if (fail) throw StateError('database or disk is full');
    created.add({
      'name': name,
      'pattern': pattern,
      'caseSensitive': caseSensitive,
      'notify': notify,
      'highlight': highlight,
      'playSound': playSound,
      'connectionId': connectionId,
    });
    return 'new-${created.length}';
  }

  @override
  Future<void> update({
    required String id,
    required String name,
    required String pattern,
    required bool caseSensitive,
    required bool notify,
    required bool highlight,
    required int? highlightColor,
    required bool playSound,
    required String? connectionId,
    required bool enabled,
  }) async {
    if (fail) throw StateError('database or disk is full');
    updated.add({'id': id, 'name': name, 'highlightColor': highlightColor, 'playSound': playSound, 'enabled': enabled});
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
