import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/ui/screens/desktop/app_closing.dart';

class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);

  int ended = 0;

  void open(int count) {
    state = {for (var i = 0; i < count; i++) 's$i': const SessionState(status: SessionStatus.connected)};
  }

  @override
  Future<void> endAllSessions() async => ended++;
}

/// A locked app has no shell, which is what answered the window's close and the
/// tray's Quit, so it could only be force closed. It
/// closes as the shell closes it: close-to-tray, the question where sessions are
/// open, and whatever fails on the way, the window goes.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  Future<({WidgetRef ref, ProviderContainer c, BuildContext context})> open(WidgetTester tester,
      {Map<String, Object> prefs = const {}, int sessions = 0}) async {
    SharedPreferences.setMockInitialValues(prefs);
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(await SharedPreferences.getInstance()),
      activeSessionsProvider.overrideWith(_Sessions.new),
    ]);
    addTearDown(c.dispose);
    (c.read(activeSessionsProvider.notifier) as _Sessions).open(sessions);
    late WidgetRef ref;
    late BuildContext context;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Consumer(builder: (ctx, r, _) {
            ref = r;
            context = ctx;
            return const SizedBox();
          }),
        ),
      ),
    ));
    return (ref: ref, c: c, context: context);
  }

  testWidgets('started locked, with nothing open: the window goes, with no question', (tester) async {
    final app = await open(tester);
    var destroyed = 0;
    var asked = 0;
    await tester.runAsync(() => closeWithoutShell(
          app.ref,
          step: ValueNotifier<String?>(null),
          l10n: en,
          question: () => app.context,
          destroy: () async => destroyed++,
          ask: (_, _) async {
            asked++;
            return true;
          },
        ));
    expect(destroyed, 1);
    expect(asked, 0);
    expect((app.c.read(activeSessionsProvider.notifier) as _Sessions).ended, 1);
  });

  testWidgets('sessions open: the question first, and No leaves everything as it was', (tester) async {
    final app = await open(tester, sessions: 2);
    var destroyed = 0;
    int? count;
    await tester.runAsync(() => closeWithoutShell(
          app.ref,
          step: ValueNotifier<String?>(null),
          l10n: en,
          question: () => app.context,
          destroy: () async => destroyed++,
          ask: (_, n) async {
            count = n;
            return false;
          },
        ));
    expect(count, 2);
    expect(destroyed, 0);
    expect((app.c.read(activeSessionsProvider.notifier) as _Sessions).ended, 0);
  });

  testWidgets('Yes: the sessions end and the window goes, even where saving the tabs fails', (tester) async {
    final app = await open(tester, sessions: 1);
    var destroyed = 0;
    await tester.runAsync(() => closeWithoutShell(
          app.ref,
          step: ValueNotifier<String?>(null),
          l10n: en,
          question: () => app.context,
          destroy: () async => destroyed++,
          ask: (_, _) async => true,
        ));
    expect(destroyed, 1);
    expect((app.c.read(activeSessionsProvider.notifier) as _Sessions).ended, 1);
  });

  testWidgets('the question turned off, or the tray\'s Quit: nothing is asked', (tester) async {
    for (final (prefs, quit) in [
      (const <String, Object>{'desktop_confirm_close_sessions': false}, false),
      (const <String, Object>{}, true),
    ]) {
      final app = await open(tester, prefs: prefs, sessions: 1);
      var destroyed = 0;
      await tester.runAsync(() => closeWithoutShell(
            app.ref,
            step: ValueNotifier<String?>(null),
            l10n: en,
            question: () => app.context,
            quit: quit,
            destroy: () async => destroyed++,
            ask: (_, _) async => fail('nothing is asked'),
          ));
      expect(destroyed, 1);
    }
  });

  testWidgets('close-to-tray: the window hides and nothing ends; Quit goes all the same', (tester) async {
    final app = await open(tester, prefs: const {'desktop_minimize_to_tray': true}, sessions: 1);
    var hidden = 0;
    var destroyed = 0;
    Future<void> close({bool quit = false}) => closeWithoutShell(
          app.ref,
          step: ValueNotifier<String?>(null),
          l10n: en,
          question: () => app.context,
          quit: quit,
          hide: () async => hidden++,
          destroy: () async => destroyed++,
          ask: (_, _) async => true,
        );
    await tester.runAsync(close);
    expect([hidden, destroyed], [1, 0]);
    expect((app.c.read(activeSessionsProvider.notifier) as _Sessions).ended, 0);

    await tester.runAsync(() => close(quit: true));
    expect([hidden, destroyed], [1, 1]);
  });

  testWidgets('a hide that fails still closes', (tester) async {
    final app = await open(tester, prefs: const {'desktop_minimize_to_tray': true});
    var destroyed = 0;
    await tester.runAsync(() => closeWithoutShell(
          app.ref,
          step: ValueNotifier<String?>(null),
          l10n: en,
          question: () => app.context,
          hide: () async => throw StateError('no tray here'),
          destroy: () async => destroyed++,
        ));
    expect(destroyed, 1);
  });
}
