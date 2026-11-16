import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/ui/screens/snippets/widgets/snippet_edit_dialog.dart';
import 'package:zestssh/utils/platform_utils.dart';

/// A phone's status bar and navigation bar (3.3): the text editor drew its own top
/// bar under the status bar, so Save could not be tapped, and the snippet editor's
/// Cancel and Save, pinned at the bottom, sat under the navigation bar. A Material
/// AppBar keeps clear of the status bar by itself; a bar of a screen's own does
/// only inside a SafeArea or with the padding added. Every full-screen Scaffold in
/// lib with no AppBar and no such care is listed below with why it is safe, and a
/// new one fails this test until someone has looked.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  group('the snippet editor on a phone', () {
    setUp(() => debugTouchLayout = true);
    tearDown(() => debugTouchLayout = null);

    testWidgets('Cancel and Save sit above the navigation bar', (tester) async {
      const size = Size(412, 915);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 40, bottom: 48);
      tester.view.viewPadding = const FakeViewPadding(top: 40, bottom: 48);
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            connectionsWithDetailsProvider.overrideWith(
              (ref) => Stream.value(const []),
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => showSnippetEditDialog(context: context),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final save = tester.getRect(
        find
            .ancestor(
              of: find.text(en.create),
              matching: find.byWidgetPredicate((w) => w is FilledButton),
            )
            .first,
      );
      final cancel = tester.getRect(find.widgetWithText(TextButton, en.cancel));
      for (final (name, rect) in [('Create', save), ('Cancel', cancel)]) {
        expect(
          rect.bottom,
          lessThanOrEqualTo(size.height - 48),
          reason: '$name above the navigation bar',
        );
      }
      final close = tester.getRect(find.byTooltip(en.close));
      expect(
        close.top,
        greaterThanOrEqualTo(40),
        reason: 'close below the status bar (its AppBar)',
      );
    });
  });

  test(
    'every full-screen Scaffold with a bar of its own keeps clear of the system bars, or is said to',
    () {
      final found = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart') || entity.path.endsWith('.g.dart')) {
          continue;
        }
        final source = entity.readAsStringSync();
        // A Scaffold itself: not ResponsiveScaffold, which gives a phone an
        // AppBar, nor one of the app's own (ZestDetailScaffold and
        // ZestStepScaffold take no care themselves: on a phone the first is only
        // ever inside a SafeArea, the second only in a dialog, 4 Nov 2026).
        if (!RegExp(r'(?<![A-Za-z_])Scaffold\(').hasMatch(source)) continue;
        final cared =
            source.contains('appBar:') ||
            source.contains('SafeArea') ||
            source.contains('padding.top') ||
            source.contains('paddingOf(context).top') ||
            source.contains('viewPadding');
        if (!cared) {
          found.add(entity.path.replaceAll('\\', '/').substring('lib/'.length));
        }
      }
      found.sort();
      final unknown = found.where((f) => !_lookedAt.containsKey(f)).toList();
      expect(
        unknown,
        isEmpty,
        reason:
            'A Scaffold with no AppBar and no SafeArea: on a phone its own bars sit under the status bar '
            'or the navigation bar. Wrap them in a SafeArea, or say why it is safe in _lookedAt: ${unknown.join(", ")}',
      );
      final gone = _lookedAt.keys.where((f) => !found.contains(f)).toList();
      expect(
        gone,
        isEmpty,
        reason:
            'These now take care themselves, or are gone: take them off _lookedAt: ${gone.join(", ")}',
      );
    },
  );
}

/// Files with a Scaffold, no AppBar and no SafeArea, and why that is safe on a phone
/// (looked at 4 Nov 2026, with the routes and pushes that reach each).
const _lookedAt = <String, String>{
  'main.dart': 'the pop-out windows of a computer (_StandaloneDetachedWindow, _StandaloneEditorWindow)',
  'ui/screens/desktop/detached_terminal_window.dart': 'a computer\'s pop-out terminal window',
  'features/screens/window/screen_window_app.dart': 'a computer\'s window of its own for a remote screen',
  'ui/screens/error/moving_data_screen.dart':
      'centred words with no bars, shown while data moves into profiles, which computers alone have',
  'ui/windows/editor_window.dart':
      'the file editor in a window of its own, which only a computer opens (its loading and could-not-open pages)',
};
