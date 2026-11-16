import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/ui/screens/home/home_screen.dart';
import 'package:zestssh/utils/platform_utils.dart';

import '../helpers/quick_wins_fixture.dart';
import 'package:zestssh/l10n/time_text.dart';

/// The phone's Sessions tab (a design review found it
/// grouped by raw IP, two web-01 rows alike, an orange bar on Disconnected
/// rows). Now grouped by the host's name with
/// its address under it; sessions to one host numbered, with when each
/// started; one whose connection has gone greyed; no bar.
final _en = lookupAppLocalizations(const Locale('en'));

final _at914 = DateTime(2026, 9, 24, 9, 14);
final _at920 = DateTime(2026, 9, 24, 9, 20);

/// Two dropped sessions to web-01 (started 9:14 and 9:20), one to db-primary
/// that started before anyone saw when, and one to mac-studio on its way.
class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref) {
    state = {
      's1': SessionState(
          status: SessionStatus.disconnected,
          connectionId: 'c0',
          connectionLabel: 'web-01',
          host: '192.168.10.21',
          lastStartedAt: _at914),
      's2': SessionState(
          status: SessionStatus.disconnected,
          connectionId: 'c0',
          connectionLabel: 'web-01',
          host: '192.168.10.21',
          lastStartedAt: _at920),
      's3': const SessionState(
          status: SessionStatus.disconnected, connectionId: 'c6', connectionLabel: 'db-primary', host: '192.168.10.31'),
      's4': SessionState.connecting('c2', connectionLabel: 'mac-studio', host: '192.168.10.30', port: 22),
    };
  }
}

/// The words of the Text at [f], or under it (a RedactedText draws one).
Text _textAt(WidgetTester tester, Finder f) =>
    tester.widget<Text>(find.descendant(of: f, matching: find.byType(Text), matchRoot: true).first);

String _text(WidgetTester tester, Finder f) => _textAt(tester, f).data!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  mockQuickWinsChannels();

  testWidgets('412 by 915: each host by its name with its address under it, its sessions numbered with when they '
      'started, a dropped one greyed, no coloured bar', (tester) async {
    debugTouchLayout = true;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await pumpQuickWins(tester, const HomeScreen(), const Size(412, 915),
          extra: [activeSessionsProvider.overrideWith(_Sessions.new)]);
      await tester.tap(find.descendant(
          of: find.byKey(const ValueKey('phone-tab-bar')), matching: find.byKey(const ValueKey('phone-tab-1'))));
      await settleQuickWins(tester);

      // The groups: by name, the address under it, in the order opened.
      final names = find.byKey(const ValueKey('sessions-group-name'));
      final addresses = find.byKey(const ValueKey('sessions-group-address'));
      expect([for (var i = 0; i < 3; i++) _text(tester, names.at(i))], ['web-01', 'db-primary', 'mac-studio']);
      expect(names, findsNWidgets(3));
      expect([for (var i = 0; i < 3; i++) _text(tester, addresses.at(i))], ['192.168.10.21', '192.168.10.31', '192.168.10.30']);
      for (var i = 0; i < 3; i++) {
        expect(tester.getTopLeft(addresses.at(i)).dy, greaterThan(tester.getTopLeft(names.at(i)).dy),
            reason: 'the address under the name');
        expect(_textAt(tester, names.at(i)).style?.fontFamily, isNot('JetBrainsMono'), reason: 'a name');
        expect(_textAt(tester, addresses.at(i)).style?.fontFamily, 'JetBrainsMono', reason: 'a value to copy');
      }
      expect(find.byKey(const ValueKey('sessions-group-count')), findsNWidgets(3));

      // Two to web-01, told apart by their numbers and when they started.
      expect(_text(tester, find.byKey(const ValueKey('session-title-s1'))), _en.sessionsTabNumbered('web-01', 1));
      expect(_text(tester, find.byKey(const ValueKey('session-title-s2'))), _en.sessionsTabNumbered('web-01', 2));
      expect(_text(tester, find.byKey(const ValueKey('session-started-s1'))), plainTimeSpaces(_en.sessionsTabStarted(_at914)));
      expect(_text(tester, find.byKey(const ValueKey('session-started-s2'))), plainTimeSpaces(_en.sessionsTabStarted(_at920)));
      expect(plainTimeSpaces(_en.sessionsTabStarted(_at914)), isNot(plainTimeSpaces(_en.sessionsTabStarted(_at920))));
      // One to a host: its name alone; no start known: no line for it.
      expect(_text(tester, find.byKey(const ValueKey('session-title-s3'))), 'db-primary');
      expect(find.byKey(const ValueKey('session-started-s3')), findsNothing);
      expect(_text(tester, find.byKey(const ValueKey('session-title-s4'))), 'mac-studio');

      // Dropped ones greyed; the one on its way not.
      double opacity(String id) => tester.widget<Opacity>(find.byKey(ValueKey('session-dim-$id'))).opacity;
      for (final id in ['s1', 's2', 's3']) {
        expect(opacity(id), lessThan(1), reason: id);
      }
      expect(opacity('s4'), 1);
      expect(
          find.descendant(of: find.byKey(const ValueKey('session-row-s1')), matching: find.text(_en.sessionsBulkStatusDisconnected)),
          findsOneWidget);

      // No bar of the host's colour at a row's edge (it was 4 wide, orange on
      // web-01's Disconnected rows).
      for (final id in ['s1', 's2', 's3', 's4']) {
        final bars = find.descendant(
            of: find.byKey(ValueKey('session-row-$id')),
            matching: find.byWidgetPredicate((w) => w is Container && w.constraints?.maxWidth == 4));
        expect(bars, findsNothing, reason: id);
      }
      // The address is the group's: the rows do not repeat it.
      expect(find.text('192.168.10.21:22'), findsNothing);

      await unpumpQuickWins(tester);
    } finally {
      debugTouchLayout = null;
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('a session keeps when it started after its connection has gone', () {
    final dropped = SessionState(status: SessionStatus.disconnected, lastStartedAt: _at914);
    expect(dropped.startedAt, _at914);
    expect(dropped.copyWith(isHidden: true).startedAt, _at914, reason: 'a copy keeps it');
    expect(dropped.withLog('dropped').startedAt, _at914, reason: 'and so does a line of its log');
    expect(const SessionState(status: SessionStatus.connecting).startedAt, isNull, reason: 'never open');
  });
}
