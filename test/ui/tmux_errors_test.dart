import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/tmux/tmux_controller.dart';
import 'package:zestssh/features/tmux/tmux_messages.dart';
import 'package:zestssh/features/tmux/tmux_session_host.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/ui/screens/tmux/tmux_session_view.dart';

/// What tmux said, where a session's tab shows it (3.0): in the
/// app's language where it is known, tmux's own words behind Copy details.
/// They were shown as they were ("tmux: ...", "tmux could not be started."
/// and the raw text, "tmux session ended: ...").
class _Controller implements TmuxController {
  _Controller({this.reason});

  final String? reason;

  @override
  void Function(String message)? onError;

  @override
  bool get exited => true;

  @override
  String? get exitReason => reason;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Host extends ChangeNotifier implements TmuxSessionHost {
  _Host({required this.stage, this.failure = '', this.controller, this.listed = const [], this.killFailure});

  @override
  final TmuxHostStage stage;

  @override
  final String failure;

  @override
  final TmuxController? controller;

  @override
  final List<TmuxSessionInfo> listed;

  final String? killFailure;

  @override
  String? lastKillFailure;

  @override
  String get sessionId => 's1';

  @override
  Future<bool> killListedSession(String sessionInfoId) async {
    lastKillFailure = killFailure;
    return false;
  }

  @override
  Future<void> restart() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  Future<ProviderContainer> open(WidgetTester tester, _Host host) async {
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(const {'tmux_intro_seen': true});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(container.dispose);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: TmuxSessionView(host: host, onLeave: () {})),
      ),
    ));
    await tester.pumpAndSettle();
    return container;
  }

  Future<String> report(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('error-details-toggle')));
    await tester.pumpAndSettle();
    return tester.widget<SelectableText>(find.byKey(const ValueKey('error-details-text'))).data!;
  }

  testWidgets("tmux that could not start: why, in the app's words, and its own words to copy", (tester) async {
    await open(tester, _Host(stage: TmuxHostStage.failed, failure: r'sessions should be nested with care, unset $TMUX to force'));
    expect(find.text(en.tmuxLaunchFailedTitle), findsOneWidget);
    expect(find.text(en.tmuxSaidNested), findsOneWidget);
    expect(await report(tester), contains('nested with care'));

    // Words it does not know: they are behind Copy details, and nothing is
    // made up about them.
    await open(tester, _Host(stage: TmuxHostStage.failed, failure: 'exit 3'));
    expect(find.text(en.tmuxLaunchFailedTitle), findsOneWidget);
    expect(find.textContaining('exit 3'), findsNothing);
    expect(await report(tester), contains('exit 3'));

    // Nothing said at all: nothing to copy either.
    await open(tester, _Host(stage: TmuxHostStage.failed));
    expect(find.byKey(const ValueKey('error-details-toggle')), findsNothing);
  });

  testWidgets('a session that ended says why, with what tmux said to copy', (tester) async {
    await open(tester, _Host(stage: TmuxHostStage.attached, controller: _Controller(reason: 'detached (from session work)')));
    expect(find.text(en.tmuxUiSessionEnded), findsOneWidget);
    expect(find.text(en.tmuxSaidDetached), findsOneWidget);
    expect(await report(tester), contains('detached (from session work)'));

    await open(tester, _Host(stage: TmuxHostStage.attached, controller: _Controller()));
    expect(find.text(en.tmuxUiSessionEnded), findsOneWidget);
    expect(find.byKey(const ValueKey('error-details-toggle')), findsNothing);
  });

  testWidgets("what tmux says to a command is said in the app's words, its own behind Copy details", (tester) async {
    final controller = _Controller(reason: 'detached');
    final c = await open(tester, _Host(stage: TmuxHostStage.attached, controller: controller));
    controller.onError!('duplicate session: work');
    var notice = c.read(notificationCenterProvider).history.first;
    expect(notice.title, en.tmuxSaidDuplicate);
    expect(notice.details, contains('duplicate session: work'));

    controller.onError!('unknown command: frobnicate');
    notice = c.read(notificationCenterProvider).history.first;
    expect(notice.title, en.tmuxSaidFailed);
    expect(notice.details, contains('unknown command: frobnicate'));
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a session that could not be killed says why', (tester) async {
    final c = await open(
      tester,
      _Host(
        stage: TmuxHostStage.picking,
        listed: const [TmuxSessionInfo(id: r'$3', name: 'work', windows: 2, attached: 0)],
        killFailure: r"can't find session: $3",
      ),
    );
    await tester.tap(find.byIcon(LucideIcons.trash2));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en.tmuxKillSession).last);
    await tester.pumpAndSettle();
    final notice = c.read(notificationCenterProvider).history.first;
    expect(notice.title, en.tmuxSaidGone);
    expect(notice.details, contains("can't find session"));
    await tester.pump(const Duration(seconds: 10));
  });

  test('what tmux said, mapped; what it is not known for, left to its own words', () {
    expect(tmuxSaid(en, r"can't find session: $3"), en.tmuxSaidGone);
    expect(tmuxSaid(en, "can't find window: @4"), en.tmuxSaidGone);
    expect(tmuxSaid(en, "can't find pane: %7"), en.tmuxSaidGone);
    expect(tmuxSaid(en, 'duplicate session: work'), en.tmuxSaidDuplicate);
    expect(tmuxSaid(en, 'no server running on /tmp/tmux-1000/default'), en.tmuxSaidNoServer);
    expect(tmuxSaid(en, 'server exited unexpectedly'), en.tmuxSaidNoServer);
    expect(tmuxSaid(en, r'sessions should be nested with care, unset $TMUX to force'), en.tmuxSaidNested);
    expect(tmuxSaid(en, 'missing or unsuitable terminal: xterm-256color'), en.tmuxSaidTerminal);
    expect(tmuxSaid(en, 'lost tty'), en.tmuxSaidTerminal);
    for (final own in ['connection closed', 'tmux control mode has ended', 'tmux exited', 'disposed', 'exited']) {
      expect(tmuxSaid(en, own), en.tmuxSaidEnded, reason: own);
    }
    expect(tmuxSaid(en, 'detached (from session work)'), en.tmuxSaidDetached);
    expect(tmuxSaid(en, 'Detached'), en.tmuxSaidDetached, reason: 'whatever its case');
    expect(tmuxSaid(en, 'unknown command: frobnicate'), isNull);
    expect(tmuxSaid(en, '   '), isNull);
  });

  test('every language says each of these its own way', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final t = lookupAppLocalizations(locale);
      final said = [
        t.tmuxSaidGone,
        t.tmuxSaidDuplicate,
        t.tmuxSaidNoServer,
        t.tmuxSaidNested,
        t.tmuxSaidTerminal,
        t.tmuxSaidEnded,
        t.tmuxSaidDetached,
        t.tmuxSaidFailed,
        t.tmuxLaunchFailedTitle,
      ];
      expect(said.toSet(), hasLength(said.length), reason: '$locale');
      if (locale.languageCode != 'en') expect(t.tmuxSaidGone, isNot(en.tmuxSaidGone), reason: '$locale');
    }
  });
}
