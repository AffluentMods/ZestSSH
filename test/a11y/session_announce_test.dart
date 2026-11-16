import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/terminal/session_announcer.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart' hide ConnectionError;
import 'package:zestssh/ui/screens/terminal/widgets/connection_error_view.dart';
import 'package:zestssh/utils/error_translator.dart';

class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);

  void set(Map<String, SessionState> s) => state = s;
}

SessionState _state(SessionStatus status) => SessionState(
      status: status,
      connectionId: 'c-web',
      connectionLabel: 'web-01',
      host: '10.0.0.21',
      port: 22,
      username: 'deploy',
    );

class _Listener extends ConsumerWidget {
  const _Listener({required this.speaks});
  final bool Function() speaks;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    listenSessionChanges(ref, context, 's1', speaks: speaks);
    return const SizedBox();
  }
}

/// A session's coming up, its dropping and a connection that failed are said
/// to a screen reader (4.0 accessibility pass): a screen reader heard nothing
/// when the terminal it was in went away. Names here are made up.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  List<String> said(WidgetTester tester) => [for (final a in tester.takeAnnouncements()) a.message];

  testWidgets('connected and dropped are said, ended or failed to connect are not, nor from a pane behind',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    var front = true;
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      activeSessionsProvider.overrideWith(_Sessions.new),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: _Listener(speaks: () => front),
      ),
    ));
    final sessions = container.read(activeSessionsProvider.notifier) as _Sessions;

    sessions.set({'s1': _state(SessionStatus.connecting)});
    await tester.pump();
    sessions.set({'s1': _state(SessionStatus.connected)});
    await tester.pump();
    expect(said(tester), [en.a11ySessionConnected('web-01')]);

    sessions.set({'s1': _state(SessionStatus.disconnected)});
    await tester.pump();
    expect(said(tester), [en.a11ySessionDropped('web-01')]);

    // A connection that never came up: its failure's view says it.
    sessions.set({'s1': _state(SessionStatus.connecting)});
    await tester.pump();
    sessions.set({'s1': _state(SessionStatus.error)});
    await tester.pump();
    expect(said(tester), isEmpty);

    // Ended by its person: it leaves the list.
    sessions.set({'s1': _state(SessionStatus.connected)});
    await tester.pump();
    tester.takeAnnouncements();
    sessions.set({});
    await tester.pump();
    expect(said(tester), isEmpty);

    // A pane behind says nothing.
    front = false;
    sessions.set({'s1': _state(SessionStatus.connecting)});
    await tester.pump();
    sessions.set({'s1': _state(SessionStatus.connected)});
    await tester.pump();
    expect(said(tester), isEmpty);
  });

  testWidgets("a phone's failed connection is said when it shows, its title a heading", (tester) async {
    L10nGlobal.update(en);
    final semantics = tester.ensureSemantics();
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    const message = 'TimeoutException after 0:00:10.000000';
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        recordingModeProvider.overrideWith((ref) => false),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: ConnectionErrorView(
            errorMessage: message,
            connectionLabel: 'web-01',
            host: 'web-01.example.com',
            port: 22,
            username: 'deploy',
            onRetry: () {},
            onEditConnection: () {},
            onGoBack: () {},
          ),
        ),
      ),
    ));
    await tester.pump();
    final title = ConnectionError.translate(message, host: 'web-01.example.com', port: 22, username: 'deploy').title;
    expect(said(tester), ['web-01: $title']);
    final heading = tester.getSemantics(find.bySemanticsLabel(title)).getSemanticsData();
    expect(heading.flagsCollection.isHeader, isTrue);
    await tester.pump();
    expect(said(tester), isEmpty, reason: 'said once');
    await tester.pump(const Duration(seconds: 3));
    semantics.dispose();
  });
}
