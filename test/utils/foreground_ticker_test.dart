import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/ui/screens/terminal/widgets/terminal_toolbar.dart';
import 'package:zestssh/utils/foreground_ticker.dart';
import 'package:zestssh/utils/platform_utils.dart' show debugTouchLayout;

/// What ticks to keep a time on screen ticks only while the app is in front:
/// the status bar's half-minute sync health clock ticked in a minimised
/// window, and the phone's session timer behind other apps, for as long as
/// the app lived (found in a review). Back in front each ticks at once.
void main() {
  void life(WidgetTester tester, AppLifecycleState state) =>
      tester.binding.handleAppLifecycleStateChanged(state);

  testWidgets('the ticker stops while hidden or in the background, and ticks at once back in front', (tester) async {
    life(tester, AppLifecycleState.resumed);
    var ticks = 0;
    final ticker = ForegroundTicker(const Duration(seconds: 30), () => ticks++);
    addTearDown(ticker.dispose);
    await tester.pump(const Duration(seconds: 61));
    expect(ticks, 2);

    life(tester, AppLifecycleState.inactive);
    await tester.pump(const Duration(seconds: 30));
    expect(ticks, 3, reason: 'inactive is still seen (a system sheet over the app)');

    life(tester, AppLifecycleState.hidden);
    expect(ticker.ticking, isFalse);
    await tester.pump(const Duration(minutes: 10));
    life(tester, AppLifecycleState.paused);
    await tester.pump(const Duration(minutes: 10));
    expect(ticks, 3, reason: 'no tick in a minimised window or behind other apps');

    life(tester, AppLifecycleState.hidden);
    life(tester, AppLifecycleState.inactive);
    expect(ticks, 4, reason: 'back in front, one tick at once');
    life(tester, AppLifecycleState.resumed);
    expect(ticks, 4, reason: 'one, not one for each state on the way back');
    await tester.pump(const Duration(seconds: 30));
    expect(ticks, 5);

    ticker.dispose();
    await tester.pump(const Duration(minutes: 5));
    expect(ticks, 5);
    life(tester, AppLifecycleState.resumed);
  });

  testWidgets('the sync health clock is silent in a minimised window', (tester) async {
    life(tester, AppLifecycleState.resumed);
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final heard = <DateTime>[];
    final sub = c.listen(syncHealthClockProvider, (_, next) {
      final v = next.valueOrNull;
      if (v != null) heard.add(v);
    });
    addTearDown(sub.close);
    await tester.pump(const Duration(seconds: 61));
    expect(heard, hasLength(2));
    life(tester, AppLifecycleState.inactive);
    life(tester, AppLifecycleState.hidden);
    await tester.pump(const Duration(minutes: 30));
    expect(heard, hasLength(2), reason: 'it ticked 60 times in half an hour minimised');
    life(tester, AppLifecycleState.inactive);
    life(tester, AppLifecycleState.resumed);
    await tester.pump();
    expect(heard, hasLength(3), reason: 'back in front, health is worked out again at once');
    sub.close();
    c.dispose();
    await tester.pump(const Duration(minutes: 1));
  });

  testWidgets('the phone\'s session timer does not tick in the background, and is right again at once', (tester) async {
    life(tester, AppLifecycleState.resumed);
    debugTouchLayout = true;
    addTearDown(() => debugTouchLayout = null);
    tester.view.physicalSize = const Size(393, 200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final connectedAt = DateTime.now().subtract(const Duration(minutes: 12, seconds: 7));
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Scaffold(
        body: TerminalToolbar(
          sessionId: 's1',
          status: SessionStatus.connected,
          connectionLabel: 'web-01',
          host: '192.168.10.21',
          port: 22,
          connectedAt: connectedAt,
          onDisconnect: () {},
          onBack: () {},
          onSettings: () {},
          onSnippets: () {},
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    final duration = find.byKey(const ValueKey('terminal-bar-duration'));
    expect(duration, findsOneWidget);

    // The timer's own element: each tick marks it to be built again. (In the
    // background the system draws no frame at all, so a frame asked for is
    // no measure there; a tick that woke the app to mark it is.)
    final chip = find.ancestor(
        of: duration, matching: find.byWidgetPredicate((w) => w.runtimeType.toString() == '_ConnectionDurationChip'));
    expect(chip, findsOneWidget);

    // In front: it ticks each second.
    await tester.binding.delayed(const Duration(seconds: 1));
    expect(tester.element(chip).dirty, isTrue);
    await tester.pump();

    life(tester, AppLifecycleState.inactive);
    life(tester, AppLifecycleState.hidden);
    life(tester, AppLifecycleState.paused);
    await tester.pump();
    var ticks = 0;
    for (var i = 0; i < 5; i++) {
      await tester.binding.delayed(const Duration(seconds: 1));
      if (tester.element(chip).dirty) ticks++;
      await tester.pump();
    }
    expect(ticks, 0, reason: 'a tick a second behind other apps');

    life(tester, AppLifecycleState.hidden);
    life(tester, AppLifecycleState.inactive);
    life(tester, AppLifecycleState.resumed);
    await tester.pump();
    final shown = tester.widget<Text>(duration).data!;
    final elapsed = DateTime.now().difference(connectedAt);
    String two(int n) => n.toString().padLeft(2, '0');
    expect(shown, '${two(elapsed.inMinutes)}:${two(elapsed.inSeconds.remainder(60))}',
        reason: 'the time is right again as soon as the app is back');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  test('outside a widget test, in front, it ticks as a periodic timer would', () async {
    var ticks = 0;
    final ticker = ForegroundTicker(const Duration(milliseconds: 10), () => ticks++);
    await Future<void>.delayed(const Duration(milliseconds: 55));
    ticker.dispose();
    expect(ticks, greaterThanOrEqualTo(3));
  });
}
