import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/wol_service.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/wake_host.dart';

/// User actions that failed with nothing shown (found in a review):
/// Wake on LAN when the host could not be asked about (the database closed
/// under the screen) returned without a word.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  setUp(() => debugTopSnackBarOnPhone = true);
  tearDown(() => debugTopSnackBarOnPhone = null);

  testWidgets('Wake on LAN that cannot ask about its host says so, and sends nothing', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() => tester.runAsync(db.close));
    final host = (await tester.runAsync(() async {
      final now = DateTime(2026, 11, 14);
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: 'h-db',
            label: 'db-primary',
            host: '192.168.10.31',
            createdAt: now,
            updatedAt: now,
            wolMacAddress: const Value('AA-BB-CC-0D-0E-0F'),
          ));
      return (await db.select(db.connections).get()).single;
    }))!;
    var sent = 0;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        hostClosedProvider.overrideWithValue((id) async => throw StateError('the database is closed')),
        wolSenderProvider.overrideWithValue(({required macAddress, required broadcastAddress, required port}) async {
          sent++;
          return const WolResult.sent(1);
        }),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: TextButton(onPressed: () => wakeHost(context, ref, host), child: const Text('wake')),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('wake'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text(l10n.devicesActionFailed), findsOneWidget);
    expect(sent, 0);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });
}
