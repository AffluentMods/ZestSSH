import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/rules/crate_offline.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/wol_service.dart';
import 'package:zestssh/ui/widgets/wake_host.dart';
import 'package:zestssh/utils/redactor.dart';

/// Waking a saved host (3.0): the one action every menu uses, on a phone
/// and on a computer. It sends for the host as it is saved, says that the
/// packet was sent and nothing more, says why where it was not, and leaves
/// a host of a closed Crate alone.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() async {
    Redactor.instance.enabled = false;
    await db.close();
  });

  /// A host as the database gives it, with what is saved for waking it.
  Future<Connection> host({String? mac = 'AA-BB-CC-0D-0E-0F', String? broadcast, int? port}) async {
    final now = DateTime(2026, 10, 9);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: 'h1',
          label: 'db-primary',
          host: '192.168.10.31',
          createdAt: now,
          updatedAt: now,
          wolMacAddress: Value(mac),
          wolBroadcastAddress: Value(broadcast),
          wolPort: Value(port),
        ));
    return (db.select(db.connections)..where((c) => c.id.equals('h1'))).getSingle();
  }

  /// What was asked to be sent: (address to wake, where to, port).
  late List<(String, String, int)> sent;

  /// Presses a button that wakes [connection], with a sender that answers
  /// [result], and gives the container the notices go to.
  Future<ProviderContainer> wake(
    WidgetTester tester,
    Connection connection, {
    WolResult result = const WolResult.sent(1),
    Future<CrateClosedOffline?> Function(String hostId)? closed,
    Locale locale = const Locale('en'),
  }) async {
    sent = [];
    final container = ProviderContainer(overrides: [
      recordingModeProvider.overrideWith((ref) => false),
      wolSenderProvider.overrideWithValue(({required macAddress, required broadcastAddress, required port}) async {
        sent.add((macAddress, broadcastAddress, port));
        return result;
      }),
      hostClosedProvider.overrideWithValue(closed ?? (_) async => null),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => Center(
              child: TextButton(onPressed: () => wakeHost(context, ref, connection), child: const Text('wake')),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('wake'));
    await tester.pumpAndSettle();
    return container;
  }

  List<AppNotification> notices(ProviderContainer c) => c.read(notificationCenterProvider).history;
  String said(AppNotification n) => [n.title, if (n.body != null) n.body].join(' ');

  test('Wake is offered for a host with an address to wake saved, and for no other', () async {
    expect(canWake(await host()), isTrue);
    await db.delete(db.connections).go();
    expect(canWake(await host(mac: null)), isFalse);
    await db.delete(db.connections).go();
    expect(canWake(await host(mac: '   ')), isFalse);
  });

  group('what is said', () {
    String text(WolResult result) =>
        wakeResultText(l10n, result, label: 'db-primary', address: 'wake.example.com', port: 70000);

    test('sent: that the packet was sent, and nothing about the machine', () {
      expect(text(const WolResult.sent(2)), l10n.homeWolSent('db-primary'));
      expect(text(const WolResult.sent(2)), 'Wake on LAN packet sent to db-primary');
      for (final claim in ['woke', 'awake', 'is up', 'online', 'responded']) {
        expect(text(const WolResult.sent(2)).toLowerCase(), isNot(contains(claim)));
      }
    });

    test('not sent: why, each in its own words, naming where it is changed', () {
      final section = l10n.connectionWakeOnLan;
      expect(text(const WolResult.failed(WolProblem.badMacAddress)), l10n.wolNotSentBadMac('db-primary', section));
      expect(text(const WolResult.failed(WolProblem.badAddress)), l10n.wolNotSentBadAddress('wake.example.com', section));
      expect(text(const WolResult.failed(WolProblem.badPort)), l10n.wolNotSentBadPort('db-primary', '70000'));
      expect(text(const WolResult.failed(WolProblem.notSent)), l10n.wolNotSentNoNetwork('db-primary'));
      final all = {for (final p in WolProblem.values) text(WolResult.failed(p))};
      expect(all, hasLength(WolProblem.values.length), reason: 'no two problems read alike');
      for (final words in all) {
        expect(words, startsWith('Not sent: '));
      }
      expect(text(const WolResult.failed(WolProblem.badMacAddress)), contains('Wake on LAN'));
      expect(text(const WolResult.failed(WolProblem.badAddress)), contains('Wake on LAN'));
    });

    test('every language has its own words for each, with the host, the address, the port and the section in them',
        () {
      final seen = <String>{};
      for (final locale in AppLocalizations.supportedLocales) {
        final words = lookupAppLocalizations(locale);
        final section = words.connectionWakeOnLan;
        final each = [
          words.wolNotSentBadMac('HOST', section),
          words.wolNotSentBadAddress('ADDRESS', section),
          words.wolNotSentBadPort('HOST', 'PORT'),
          words.wolNotSentNoNetwork('HOST'),
        ];
        expect(each[0], allOf(contains('HOST'), contains(section), contains('AA:BB:CC:DD:EE:FF')), reason: '$locale');
        expect(each[1], allOf(contains('ADDRESS'), contains(section)), reason: '$locale');
        expect(each[2], allOf(contains('HOST'), contains('PORT'), contains('9')), reason: '$locale');
        expect(each[3], contains('HOST'), reason: '$locale');
        expect(words.hostPanelWakeHint.trim(), isNotEmpty, reason: '$locale');
        seen.addAll(each);
        seen.add(words.hostPanelWakeHint);
      }
      expect(seen, hasLength(AppLocalizations.supportedLocales.length * 5), reason: 'each language has its own');
    });
  });

  group('waking a host', () {
    testWidgets('sends for the host as it is saved, and says that the packet was sent', (tester) async {
      final connection = (await tester.runAsync(() => host(broadcast: '192.168.10.255', port: 7)))!;
      final c = await wake(tester, connection);
      expect(sent, [('AA-BB-CC-0D-0E-0F', '192.168.10.255', 7)]);
      expect(said(notices(c).single), l10n.homeWolSent('db-primary'));
      expect(notices(c).single.severity, NotificationSeverity.success);
      await tester.pump(const Duration(minutes: 1));
    });

    testWidgets('where the host names no address or port: every machine on the network, on port 9', (tester) async {
      final connection = (await tester.runAsync(() => host(mac: '  aa:bb:cc:0d:0e:0f ', broadcast: '  ')))!;
      await wake(tester, connection);
      expect(sent, [('aa:bb:cc:0d:0e:0f', '255.255.255.255', 9)]);
      await tester.pump(const Duration(minutes: 1));
    });

    testWidgets('not sent: says why as an error, with what was caught to copy', (tester) async {
      final connection = (await tester.runAsync(host))!;
      final c = await wake(tester, connection,
          result: const WolResult.failed(WolProblem.notSent, 'SocketException: Network is unreachable'));
      expect(sent, hasLength(1));
      final notice = notices(c).single;
      expect(said(notice), l10n.wolNotSentNoNetwork('db-primary'));
      expect(notice.severity, NotificationSeverity.error);
      expect(notice.details, contains('Network is unreachable'));
    });

    testWidgets('a name that was not found is named in what is said', (tester) async {
      final connection = (await tester.runAsync(() => host(broadcast: 'wake.example.com')))!;
      final c = await wake(tester, connection, result: const WolResult.failed(WolProblem.badAddress, 'No address'));
      expect(said(notices(c).single), l10n.wolNotSentBadAddress('wake.example.com', l10n.connectionWakeOnLan));
    });

    testWidgets('a host whose Crate is closed on this device is not woken, and the Crate says why', (tester) async {
      final connection = (await tester.runAsync(host))!;
      final asked = <String>[];
      final c = await wake(tester, connection, closed: (id) async {
        asked.add(id);
        return const CrateClosedOffline(crateId: 'crate-1', hours: 24, message: 'Production is closed on this device.');
      });
      expect(asked, ['h1']);
      expect(sent, isEmpty, reason: 'nothing a closed Crate holds is used');
      expect(said(notices(c).single), 'Production is closed on this device.');
      expect(notices(c).single.severity, NotificationSeverity.warning);
      await tester.pump(const Duration(minutes: 1));
    });

    testWidgets('a host that cannot be asked about (the app locked under the screen) is not woken, and that is said',
        (tester) async {
      final connection = (await tester.runAsync(host))!;
      final c = await wake(tester, connection, closed: (_) async => throw StateError('Database is locked'));
      expect(sent, isEmpty);
      // It returned with nothing said (found in a review).
      expect(notices(c).map(said), [l10n.devicesActionFailed]);
    });

    testWidgets('a host with no address to wake: nothing is asked, sent or said', (tester) async {
      final connection = (await tester.runAsync(() => host(mac: null)))!;
      final asked = <String>[];
      final c = await wake(tester, connection, closed: (id) async {
        asked.add(id);
        return null;
      });
      expect(asked, isEmpty);
      expect(sent, isEmpty);
      expect(notices(c), isEmpty);
    });

    testWidgets('while recording, neither the host nor its address is named', (tester) async {
      final connection = (await tester.runAsync(() => host(broadcast: 'wake.example.com')))!;
      Redactor.instance.enabled = true;
      var c = await wake(tester, connection);
      expect(said(notices(c).single), isNot(contains('db-primary')));
      await tester.pump(const Duration(minutes: 1));
      c = await wake(tester, connection, result: const WolResult.failed(WolProblem.badAddress));
      expect(said(notices(c).single), isNot(contains('wake.example.com')));
    });

    testWidgets('it is said in the language of the app', (tester) async {
      final connection = (await tester.runAsync(host))!;
      final c = await wake(tester, connection, locale: const Locale('de'));
      expect(said(notices(c).single), lookupAppLocalizations(const Locale('de')).homeWolSent('db-primary'));
      await tester.pump(const Duration(minutes: 1));
    });
  });
}
