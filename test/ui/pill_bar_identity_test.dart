import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/desktop/widgets/pill_bar.dart';

SessionState _state(String label) => SessionState(
      status: SessionStatus.connected,
      connectionId: 'c-$label',
      connectionLabel: label,
      host: '10.50.0.5',
      port: 22,
      username: 'deploy',
    );

/// A tab's colour bar: the colour of its host, or of the host's group, down
/// the tab's left edge; one band for each colour when a tab holds hosts of
/// several. (3.0, found while the tab strip was rendered
/// for its drag marks: since 1.7.0 the bar was laid out four pixels wide and
/// its colour none, so no tab ever showed one.)
void main() {
  const orange = Color(0xFFFF7A1A);
  const blue = Color(0xFF4FA3FF);
  const green = Color(0xFF36C275);

  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  Future<void> pumpStrip(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        // The strip's sync glyph ticks every 30 seconds: no clock here.
        syncHealthClockProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: PillBar(
              activeNav: NavSection.hosts,
              activeSessionId: 't2',
              sessions: [
                MapEntry('t1', _state('web-01')),
                MapEntry('t2', _state('db-01, cache-01')),
                MapEntry('t3', _state('queue-01')),
                MapEntry('t4', _state('build-01, build-02')),
              ],
              tabIdentityColors: const {
                't1': [orange],
                't2': [blue, green],
                't4': [orange, orange],
              },
              onNavChanged: (_) {},
              onSessionSelected: (_) {},
              onSessionClosed: (_) {},
              onNewSession: () {},
              onCommandPalette: () {},
              onHelp: () {},
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  /// The bands of the tab [id]'s colour bar, top to bottom.
  List<({Color color, Rect rect})> bands(WidgetTester tester, String id) {
    final found = find.descendant(of: find.byKey(ValueKey(id)), matching: find.byType(ColoredBox));
    Rect rectOf(Element e) {
      final box = e.renderObject! as RenderBox;
      return box.localToGlobal(Offset.zero) & box.size;
    }

    return [
      for (final e in found.evaluate()) (color: (e.widget as ColoredBox).color, rect: rectOf(e)),
    ]..sort((a, b) => a.rect.top.compareTo(b.rect.top));
  }

  /// How solid the tab [id]'s colour bar is drawn.
  double solidity(WidgetTester tester, String id) {
    final bar = find.descendant(of: find.byKey(ValueKey(id)), matching: find.byType(ColoredBox)).first;
    return tester.widget<Opacity>(find.ancestor(of: bar, matching: find.byType(Opacity)).first).opacity;
  }

  testWidgets('a tab shows its host\'s colour down its left edge', (tester) async {
    await pumpStrip(tester);
    final tab = tester.getRect(find.byKey(const ValueKey('t1')));
    final bar = bands(tester, 't1');
    expect(bar, hasLength(1));
    expect(bar.single.color, orange);
    expect(bar.single.rect.width, 4, reason: 'it was laid out with no width at all');
    expect(bar.single.rect.height, greaterThan(30), reason: 'the tab\'s height, inside its border');
    expect(bar.single.rect.left, closeTo(tab.left, 1.5), reason: 'at the tab\'s left edge');
  });

  testWidgets('a tab of hosts with several colours shows a band for each, in their order', (tester) async {
    await pumpStrip(tester);
    final bar = bands(tester, 't2');
    expect(bar.map((b) => b.color), [blue, green]);
    expect(bar.first.rect.width, 4);
    expect(bar.last.rect.width, 4);
    expect(bar.first.rect.height, bar.last.rect.height, reason: 'the same share each');
    expect(bar.last.rect.top, bar.first.rect.bottom);
  });

  testWidgets('hosts of the same colour make one band, and a tab with no colour a neutral one', (tester) async {
    await pumpStrip(tester);
    final same = bands(tester, 't4');
    expect(same, hasLength(1));
    expect(same.single.color, orange);
    final none = bands(tester, 't3');
    expect(none, hasLength(1));
    expect(none.single.color, AppColors.neutralLabelColor);
    expect(none.single.rect.width, 4);
  });

  testWidgets('the tab in front shows its colour in full, the others dimmed', (tester) async {
    await pumpStrip(tester);
    expect(solidity(tester, 't2'), 1.0);
    expect(solidity(tester, 't1'), 0.6);
    expect(solidity(tester, 't3'), 0.6);
  });
}
