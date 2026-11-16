import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/screens/desktop/app_closing.dart';

/// Closing the app on a computer (closing it sometimes took some ten
/// seconds, with nothing to show that it was not
/// frozen). The open tabs were saved into the app's database, where a
/// sync's writes come first, and the other windows were each waited for,
/// without a limit and with nothing on screen. Now each step is said over the
/// window while it runs, none is waited for past its limit, and the app
/// closes whatever a step does.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  testWidgets('each step is said while it runs; a step that never finishes is left at its limit; the close goes on',
      (tester) async {
    final step = ValueNotifier<String?>(null);
    final said = <String?>[];
    step.addListener(() => said.add(step.value));
    var windows = false;
    var sessions = false;
    var closed = false;
    final never = Completer<void>();
    unawaited(runClosingSteps(step, [
      ClosingStep('Saving', () => never.future, limit: kClosingSaveLimit),
      ClosingStep('Windows', () async => windows = true, limit: kClosingWindowsLimit),
      ClosingStep('Sessions', () => sessions = true),
    ]).then((_) => closed = true));
    await tester.pump();
    expect(step.value, 'Saving');
    await tester.pump(kClosingSaveLimit - const Duration(milliseconds: 1));
    expect(windows, isFalse, reason: 'the save is waited for until its limit');
    await tester.pump(const Duration(milliseconds: 2));
    expect([windows, sessions, closed], [true, true, true]);
    expect(said, ['Saving', 'Windows', 'Sessions']);
  });

  test('a step that fails does not stop the close', () async {
    final step = ValueNotifier<String?>(null);
    var after = false;
    await runClosingSteps(step, [
      ClosingStep('Fails', () => throw StateError('a pop-out window that is gone')),
      ClosingStep('After', () => after = true),
    ]);
    expect(after, isTrue);
  });

  testWidgets('the panel: nothing while the app is not closing; while it closes, that ZestSSH is closing, the step, '
      'and no click goes through', (tester) async {
    final step = ValueNotifier<String?>(null);
    var tapped = 0;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Scaffold(
        body: Stack(children: [
          Center(child: GestureDetector(onTap: () => tapped++, child: const Text('the app'))),
          Positioned.fill(child: ClosingPanel(step: step)),
        ]),
      ),
    ));
    expect(find.byKey(const ValueKey('app-closing')), findsNothing);
    await tester.tap(find.text('the app'));
    expect(tapped, 1);

    step.value = l10n.desktopClosingSaving;
    await tester.pump();
    expect(find.text(l10n.desktopClosingTitle), findsOneWidget);
    expect(find.text(l10n.desktopClosingSaving), findsOneWidget);
    await tester.tap(find.text('the app'), warnIfMissed: false);
    expect(tapped, 1, reason: 'the app takes no click while it closes');

    step.value = l10n.desktopClosingSessions;
    await tester.pump();
    expect(find.text(l10n.desktopClosingSessions), findsOneWidget);
    expect(find.text(l10n.desktopClosingSaving), findsNothing);
  });

  test('its words in every language: the app closing by its name, and each step', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final words = lookupAppLocalizations(locale);
      expect(words.desktopClosingTitle, contains('ZestSSH'), reason: '$locale');
      final steps = {words.desktopClosingSaving, words.desktopClosingWindows, words.desktopClosingSessions};
      expect(steps, hasLength(3), reason: '$locale: three different steps');
    }
  });

  test("the computer's shell closes through these steps, each save and window waited for within its limit, the panel "
      'over it (read from its file: nothing draws the whole shell closing in a test)', () {
    final shell = File('lib/ui/screens/desktop/desktop_shell.dart').readAsStringSync();
    expect(shell, contains('await runClosingSteps(_closingStep, ['));
    expect(shell, contains('}, limit: kClosingSaveLimit),'));
    expect(shell, contains('MultiWindowService.instance.closeAllWindows, limit: kClosingWindowsLimit),'));
    expect(shell, contains('Positioned.fill(child: ClosingPanel(step: _closingStep)),'));
  });
}
