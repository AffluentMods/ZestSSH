import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/ui/screens/replay/session_replay_screen.dart';

/// A session's replay says what it is in the person's language. Its title
/// was the host's name, a dash and the English word ("web-01 - Replay"), and
/// its play button's tooltip "Play" or "Pause", in every language (the
/// screenshot tests found it).
void main() {
  Future<AppLocalizations> pump(WidgetTester tester, Locale locale, {String host = 'web-01'}) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final data = SessionReplayData(
      sessionId: 's0',
      connectionLabel: host,
      startedAt: DateTime(2026, 11, 12, 9, 12),
      entries: const [
        RecordingEntry(timestamp: Duration.zero, data: 'deploy@web-01:~\$ '),
        RecordingEntry(timestamp: Duration(seconds: 5), data: 'uptime\r\n'),
      ],
    );
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SessionReplayScreen(data: data),
      ),
    ));
    await tester.pump();
    return lookupAppLocalizations(locale);
  }

  testWidgets('the title names the host, with no dash, and the button says Play', (tester) async {
    final en = await pump(tester, const Locale('en'));
    expect(find.text('Replay of web-01'), findsOneWidget);
    expect(find.textContaining(' - '), findsNothing);
    expect(find.byTooltip(en.replayPlay), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('in German both are German', (tester) async {
    final de = await pump(tester, const Locale('de'));
    expect(find.text(de.replayTitle('web-01')), findsOneWidget);
    expect(de.replayTitle('web-01'), isNot(contains('Replay')));
    expect(find.byTooltip(de.replayPlay), findsOneWidget);
    expect(find.byTooltip('Play'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a recording that names no host still has a title', (tester) async {
    final en = await pump(tester, const Locale('en'), host: '');
    expect(find.text(en.replayTitleNoHost), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  test('every language has its own words for the four', () {
    final en = lookupAppLocalizations(const Locale('en'));
    for (final locale in AppLocalizations.supportedLocales) {
      if (locale.languageCode == 'en') continue;
      final l = lookupAppLocalizations(locale);
      expect(l.replayTitle('web-01'), contains('web-01'), reason: '$locale');
      expect(l.replayTitle('web-01'), isNot(en.replayTitle('web-01')), reason: '$locale');
      expect(l.replayTitleNoHost, isNot(en.replayTitleNoHost), reason: '$locale');
      expect(l.replayPlay, isNot(en.replayPlay), reason: '$locale');
      expect(l.replayPause, isNot(en.replayPause), reason: '$locale');
    }
  });
}
