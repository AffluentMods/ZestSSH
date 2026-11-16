// The row of keys above a phone's or a tablet's keyboard (3.2.1):
// every key is as wide as the next, in both
// layouts and both styles, so the rows stand in columns; Grouped outlines the
// arrows with Home and End, Flat does not; Small, Medium and Large keys in
// either layout; the scrollable row's keys share a tablet's width up to a
// widest key and then stand in the middle, and on a phone they scroll; the
// keys Settings hides or orders are hidden and ordered in the two rows too;
// and while a hardware keyboard is typed on, the row can keep only the keys
// such a keyboard lacks. At phones' and tablets' widths, upright and on their
// side, nothing runs over. The keys do what they did.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/screens/settings/keyboard_row_screen.dart';
import 'package:zestssh/ui/screens/terminal/widgets/soft_key_catalog.dart';
import 'package:zestssh/ui/screens/terminal/widgets/terminal_soft_keyboard.dart';

void main() {
  final sent = <String>[];

  setUpAll(() async {
    final loader = FontLoader('JetBrainsMono');
    for (final f in ['assets/fonts/JetBrainsMono-Regular.ttf', 'assets/fonts/JetBrainsMono-Bold.ttf']) {
      loader.addFont(Future.value(ByteData.view(File(f).readAsBytesSync().buffer)));
    }
    await loader.load();
  });

  Future<void> pump(
    WidgetTester tester, {
    required Size size,
    Map<String, Object> prefs = const {},
    bool onlyMissingKeys = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(prefs);
    final store = await SharedPreferences.getInstance();
    sent.clear();
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(store)],
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: TerminalSoftKeyboard(onKey: sent.add, onlyMissingKeys: onlyMissingKeys),
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  Finder key(String id) => find.byKey(ValueKey('softkey-$id'));
  Rect rect(WidgetTester tester, String id) => tester.getRect(key(id));

  /// Every key the row draws, by its id.
  Map<String, Rect> keys(WidgetTester tester) => {
        for (final e in find.byWidgetPredicate((w) => w is KeyedSubtree && w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('softkey-') &&
            !(w.key! as ValueKey<String>).value.startsWith('softkey-cluster')).evaluate())
          ((e.widget.key! as ValueKey<String>).value.substring(8)): tester.getRect(find.byWidget(e.widget)),
      };

  const screens = {
    'a small phone': Size(360, 780),
    'a large phone': Size(430, 932),
    'a tablet upright': Size(1024, 1366),
    'a phone on its side': Size(800, 360),
    'a tablet on its side': Size(1280, 800),
  };
  const heights = {
    SoftKeySize.small: (36.0, 28.0),
    SoftKeySize.medium: (44.0, 32.0),
    SoftKeySize.large: (52.0, 38.0),
  };

  for (final screen in screens.entries) {
    final landscape = screen.value.width > screen.value.height;
    for (final scrollable in [false, true]) {
      for (final style in SoftKeyRowStyle.values) {
        for (final size in SoftKeySize.values) {
          final layout = scrollable ? 'scrollable' : 'two rows';
          testWidgets('$layout, ${style.name}, ${size.name}, ${screen.key}: every key one width, in columns, nothing over',
              (tester) async {
            await pump(tester, size: screen.value, prefs: {
              'soft_keyboard_scrollable_mode': scrollable,
              'soft_keyboard_style': style.name,
              'soft_keyboard_key_size': size.name,
            });
            expect(tester.takeException(), isNull);
            final all = keys(tester);
            expect(all, isNotEmpty);
            final height = landscape ? heights[size]!.$2 : heights[size]!.$1;
            final widths = {for (final r in all.values) r.width};
            expect(widths.length, 1, reason: 'every key as wide as the next: $widths');
            for (final e in all.entries) {
              // FN stands as tall as the rows.
              if (e.key == 'fn') continue;
              expect(e.value.height, height, reason: '${e.key} at ${size.name}');
            }
            // The two rows stand in columns: each key's left is a column's.
            final lefts = {for (final r in all.values) r.left.roundToDouble()};
            final step = widths.single + switch (size) {
              SoftKeySize.small => 3,
              SoftKeySize.medium => 4,
              SoftKeySize.large => 5,
            };
            final first = lefts.reduce((a, b) => a < b ? a : b);
            for (final l in lefts) {
              final columns = (l - first) / step;
              expect((columns - columns.round()).abs(), lessThan(0.05), reason: 'a key off its column at $l');
            }
            // Nothing runs off the screen where the row does not scroll.
            if (!scrollable) {
              for (final e in all.entries) {
                expect(e.value.left, greaterThanOrEqualTo(0), reason: e.key);
                expect(e.value.right, lessThanOrEqualTo(screen.value.width), reason: e.key);
              }
            }
            final outlines = find.byKey(const ValueKey('softkey-cluster'));
            expect(outlines, style == SoftKeyRowStyle.grouped ? findsOneWidget : findsNothing);
          });
        }
      }
    }
  }

  testWidgets('two rows, upright: HOME ↑ END stand over ← ↓ →, inside one outline; FN as tall as the rows',
      (tester) async {
    await pump(tester, size: const Size(390, 844));
    for (final (top, bottom) in [('home', 'left'), ('up', 'down'), ('end', 'right')]) {
      expect(rect(tester, top).left, rect(tester, bottom).left, reason: '$top over $bottom');
      expect(rect(tester, top).bottom, lessThan(rect(tester, bottom).top));
    }
    final outline = tester.getRect(find.byKey(const ValueKey('softkey-cluster')));
    for (final id in softKeyClusterIds) {
      expect(outline.contains(rect(tester, id).center), isTrue, reason: id);
    }
    expect(outline.contains(rect(tester, 'tilde').center), isFalse);
    expect(rect(tester, 'fn').top, rect(tester, 'esc').top);
    expect(rect(tester, 'fn').bottom, rect(tester, 'tab').bottom);
    for (final id in fnPageSoftKeyIds) {
      expect(key(id), findsNothing, reason: '$id is on the FN page');
    }
  });

  testWidgets('each key sends what it sent; an arrow held repeats; CTRL holds on; FN shows the F keys and comes back',
      (tester) async {
    await pump(tester, size: const Size(360, 780));
    for (final id in ['esc', 'slash', 'pipe', 'minus', 'tilde', 'home', 'up', 'end', 'tab', 'left', 'down', 'right', 'del']) {
      await tester.tap(key(id));
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(sent, ['\x1B', '/', '|', '-', '~', '\x1B[H', '\x1B[A', '\x1B[F', '\t', '\x1B[D', '\x1B[B', '\x1B[C', '\x1B[3~']);

    sent.clear();
    final gesture = await tester.startGesture(tester.getCenter(key('up')));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 1000));
    await gesture.up();
    await tester.pump();
    expect(sent.length, greaterThan(2));
    expect(sent.toSet(), {'\x1B[A'});

    await tester.tap(find.text('CTRL'));
    await tester.pump();
    final ctrl = tester.widget<Semantics>(find
        .ancestor(of: find.text('CTRL'), matching: find.byWidgetPredicate((w) => w is Semantics && w.properties.toggled != null))
        .first);
    expect(ctrl.properties.toggled, isTrue);

    await tester.tap(key('fn'));
    await tester.pump();
    for (final id in fnPageSoftKeyIds) {
      expect(key(id), findsOneWidget, reason: '$id on the FN page');
    }
    expect(key('home'), findsNothing);
    sent.clear();
    await tester.tap(key('pgup'));
    await tester.tap(key('f12'));
    await tester.pump();
    expect(sent, ['\x1B[5~', '\x1B[24~']);
    await tester.tap(key('back'));
    await tester.pump();
    expect(key('home'), findsOneWidget);
  });

  for (final screen in {'a phone on its side': const Size(800, 360), 'a tablet on its side': const Size(1280, 800)}.entries) {
    testWidgets('two rows, ${screen.key}: one row, its arrows, Home and End one block; the FN page has every F key, PgUp, PgDn and INS',
        (tester) async {
      await pump(tester, size: screen.value);
      final tops = {for (final r in keys(tester).values) r.top};
      expect(tops.length, 1, reason: 'one row');
      final order = (keys(tester).entries.toList()..sort((a, b) => a.value.left.compareTo(b.value.left))).map((e) => e.key).toList();
      expect(order, ['esc', 'slash', 'pipe', 'minus', 'tab', 'ctrl', 'alt', 'del', 'home', 'up', 'end', 'left', 'down', 'right', 'tilde', 'mic', 'fn']);
      await tester.tap(key('fn'));
      await tester.pump();
      for (final id in fnPageSoftKeyIds) {
        expect(key(id), findsOneWidget, reason: id);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('two rows: the keys Settings hides are gone, and its order is the rows\' order', (tester) async {
    await pump(tester, size: const Size(390, 844), prefs: {
      'soft_keyboard_disabled_keys': 'tilde,pipe,f12',
      'soft_keyboard_row1_order': ['minus', 'esc', 'slash', 'pipe', 'home', 'up', 'end', 'tilde', 'f1', 'f2', 'f3', 'f4', 'f5', 'f6', 'f7', 'f8'],
      'soft_keyboard_row2_order': ['tab', 'ctrl', 'alt', 'del', 'left', 'down', 'right', 'mic', 'f9', 'f10', 'f11', 'f12', 'pgup', 'pgdn', 'ins'],
    });
    expect(key('tilde'), findsNothing);
    expect(key('pipe'), findsNothing);
    expect(rect(tester, 'minus').left, lessThan(rect(tester, 'esc').left), reason: 'the order Settings has');
    await tester.tap(key('fn'));
    await tester.pump();
    expect(key('f12'), findsNothing);
    expect(key('f11'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets("the scrollable row on a tablet: its keys share the width up to the widest, then stand in the middle",
      (tester) async {
    // 1366 wide: a share of 81 is over Medium's widest key.
    await pump(tester, size: const Size(1366, 1024), prefs: {'soft_keyboard_scrollable_mode': true});
    final all = keys(tester);
    expect(all.length, defaultSoftRow1.length + defaultSoftRow2.length);
    final width = all.values.first.width;
    expect(width, 76, reason: "Medium's widest key");
    final left = all.values.map((r) => r.left).reduce((a, b) => a < b ? a : b);
    final right = all.values.map((r) => r.right).reduce((a, b) => a > b ? a : b);
    expect((left - (1366 - right)).abs(), lessThan(2), reason: 'in the middle');
    expect(find.byType(SingleChildScrollView), findsNothing, reason: 'nothing to scroll');
  });

  testWidgets('the scrollable row on a phone keeps its keys at their size and scrolls', (tester) async {
    await pump(tester, size: const Size(390, 844), prefs: {'soft_keyboard_scrollable_mode': true, 'soft_keyboard_key_size': 'small'});
    expect(keys(tester).values.first.width, 44);
    final scroll = find.byType(SingleChildScrollView);
    final position = tester.state<ScrollableState>(find.descendant(of: scroll, matching: find.byType(Scrollable))).position;
    expect(position.maxScrollExtent, greaterThan(100), reason: 'the F keys are a swipe away');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a hardware keyboard typed on, upright: only the keys it lacks, INS HOME PgUp over DEL END PgDn',
      (tester) async {
    await pump(tester, size: const Size(1024, 1366), onlyMissingKeys: true);
    expect(keys(tester).keys.toSet(), hardwareMissingKeyIds.toSet());
    for (final (top, bottom) in [('ins', 'del'), ('home', 'end'), ('pgup', 'pgdn')]) {
      expect(rect(tester, top).left, rect(tester, bottom).left, reason: '$top over $bottom');
    }
    await tester.tap(key('ins'));
    await tester.tap(key('pgdn'));
    await tester.pump();
    expect(sent, ['\x1B[2~', '\x1B[6~']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a hardware keyboard typed on, on its side: the keys it lacks in one row', (tester) async {
    await pump(tester, size: const Size(1280, 800), onlyMissingKeys: true);
    final all = keys(tester);
    expect(all.keys.toSet(), hardwareMissingKeyIds.toSet());
    expect({for (final r in all.values) r.top}.length, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets("Settings' Keyboard row page: sizes, two styles, three ways with a hardware keyboard, and the keys in two rows",
      (tester) async {
    tester.view.physicalSize = const Size(430, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: const KeyboardRowScreen(),
      ),
    ));
    await tester.pump();
    bool picked(String k) => tester.widget<ListTile>(find.byKey(ValueKey(k))).selected;
    for (final s in SoftKeyRowStyle.values) {
      expect(find.byKey(ValueKey('keys-row-style-${s.name}')), findsOneWidget);
    }
    expect(picked('keys-row-style-grouped'), isTrue);
    expect(picked('keys-row-size-medium'), isTrue);
    expect(picked('keys-row-hardware-auto'), isTrue, reason: "a phone's default: hide");
    expect(find.byKey(const ValueKey('keys-row-hardware-missing')), findsOneWidget);
    expect(find.byKey(const ValueKey('keys-row-fn-page-note')), findsOneWidget, reason: 'the keys of the two rows');
    expect(find.byKey(const ValueKey('keys-row-visible-tilde')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('keys-row-size-large')));
    await tester.tap(find.byKey(const ValueKey('keys-row-style-flat')));
    await tester.tap(find.byKey(const ValueKey('keys-row-hardware-missing')));
    await tester.pump();
    expect(container.read(softKeyboardKeySizeProvider), SoftKeySize.large);
    expect(container.read(softKeyboardStyleProvider), SoftKeyRowStyle.flat);
    expect(container.read(keysRowHardwareProvider), HardwareKeysRow.missingOnly);
    expect(prefs.getString('soft_keyboard_key_size'), 'large');
    expect(prefs.getString('keys_row_hardware'), 'missingOnly');
    expect(picked('keys-row-size-large'), isTrue);
    expect(find.byKey(const ValueKey('softkeys-flat')), findsOneWidget, reason: 'the preview follows');
    expect(tester.takeException(), isNull);

    await SettingsService(prefs).resetAllToDefaults();
    expect(prefs.getString('soft_keyboard_key_size'), isNull);
    expect(prefs.getString('keys_row_hardware'), isNull);
  });

  testWidgets("Settings' Keyboard row page on a tablet: Keep the keys it lacks is picked until another is", (tester) async {
    tester.view.physicalSize = const Size(1024, 1366);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: const KeyboardRowScreen(),
      ),
    ));
    await tester.pump();
    expect(tester.widget<ListTile>(find.byKey(const ValueKey('keys-row-hardware-missing'))).selected, isTrue);
  });

  test("3.1's settings read as 3.2.1's: Compact is Grouped at Small, the hardware switch is Hide or Always", () async {
    SharedPreferences.setMockInitialValues({'soft_keyboard_style': 'compact', 'keys_row_auto_hide': false});
    var s = SettingsService(await SharedPreferences.getInstance());
    expect(SoftKeyRowStyle.fromId(s.softKeyboardStyle), SoftKeyRowStyle.grouped);
    expect(SoftKeySize.fromId(s.softKeyboardKeySize), SoftKeySize.small);
    expect(HardwareKeysRow.fromId(s.keysRowHardware), HardwareKeysRow.always);

    SharedPreferences.setMockInitialValues({'soft_keyboard_style': 'flat', 'keys_row_auto_hide': true});
    s = SettingsService(await SharedPreferences.getInstance());
    expect(SoftKeySize.fromId(s.softKeyboardKeySize), SoftKeySize.medium);
    expect(HardwareKeysRow.fromId(s.keysRowHardware), HardwareKeysRow.hide);

    SharedPreferences.setMockInitialValues({});
    s = SettingsService(await SharedPreferences.getInstance());
    expect(HardwareKeysRow.fromId(s.keysRowHardware), isNull, reason: "the device's default");
    expect(HardwareKeysRow.defaultFor(tablet: true), HardwareKeysRow.missingOnly);
    expect(HardwareKeysRow.defaultFor(tablet: false), HardwareKeysRow.hide);
    expect(SoftKeyRowStyle.fromId('fancy'), SoftKeyRowStyle.grouped);
  });

  // A change of the key row on the
  // tablet changed the phone's. Its settings stay on each device since 3.2.
  test("the key row's settings stay on each device", () {
    for (final key in [
      'show_extra_keyboard',
      'extra_keyboard_position',
      'soft_keyboard_style',
      'soft_keyboard_key_size',
      'soft_keyboard_scrollable_mode',
      'soft_keyboard_disabled_keys',
      'soft_keyboard_row1_order',
      'soft_keyboard_row2_order',
      'keys_row_hardware',
    ]) {
      expect(SettingsService.isSyncedSettingKey(key), isFalse, reason: key);
    }
    expect(SettingsService.isSyncedSettingKey('terminal_font'), isTrue, reason: 'the rest still syncs');
  });
}
