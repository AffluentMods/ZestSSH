import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/ui/screens/home/home_screen.dart';
import 'package:zestssh/ui/screens/identity/identity_list_screen.dart';
import 'package:zestssh/ui/screens/identity/key_users.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/platform_utils.dart' show debugTouchLayout;

import '../helpers/quick_wins_fixture.dart';

/// Deleting a key names the hosts that sign in with it, up to five, then how
/// many more (in a 4.0 review, "This key is used by 3
/// hosts" named none of them).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  mockQuickWinsChannels();
  final l10n = lookupAppLocalizations(const Locale('en'));

  List<String> webs(int n) => [for (var i = 1; i <= n; i++) 'web-0$i'];

  group('the lines', () {
    test('up to five hosts by name, in the order given', () {
      expect(keyUsersLinesOf(l10n, webs(3)), ['web-01', 'web-02', 'web-03']);
      expect(keyUsersLinesOf(l10n, webs(5)), webs(5));
    });

    test('past five, the first five and how many more', () {
      expect(keyUsersLinesOf(l10n, webs(6)), [...webs(5), 'and 1 more host']);
      expect(keyUsersLinesOf(l10n, webs(8)), [...webs(5), 'and 3 more hosts']);
    });

    test('none, no lines', () {
      expect(keyUsersLinesOf(l10n, const []), isEmpty);
    });
  });

  /// Runs [body] drawn as a phone's.
  void phone(String name, Future<void> Function(WidgetTester tester) body) {
    testWidgets(name, (tester) async {
      debugTouchLayout = true;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await body(tester);
      } finally {
        debugTouchLayout = null;
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  Finder dialog() => find.byType(ZestConfirmDialog);

  List<String> bulletsShown(WidgetTester tester) => tester.widget<ZestConfirmDialog>(dialog()).bullets ?? const [];

  /// The phone's Keys, with a way to open a key's own sheet (as the
  /// selection's More does).
  Future<(BuildContext, WidgetRef, AppDatabase)> keys(WidgetTester tester) async {
    late BuildContext context;
    late WidgetRef ref;
    final (key: _, :container, :db) = await pumpQuickWins(
      tester,
      Consumer(
        builder: (ctx, r, _) {
          context = ctx;
          ref = r;
          return const KeysPhoneScreen();
        },
      ),
      quickWinsPhone,
    );
    // The keys as the app has them read by then (the sheet reads them).
    container.listen(identitiesProvider, (_, _) {});
    await settleQuickWins(tester);
    return (context, ref, db);
  }

  Future<void> deleteFromSheet(WidgetTester tester, BuildContext context, WidgetRef ref, String id) async {
    openPhoneKeySheet(context, ref, id);
    await settleQuickWins(tester);
    await tester.tap(find.widgetWithText(ListTile, l10n.delete).last);
    await settleQuickWins(tester);
  }

  phone("a phone's Keys: Delete names the five hosts that use the key, then how many more", (tester) async {
    final (context, ref, db) = await keys(tester);
    // Ops laptop signs in on five of the hosts (all but edge-router and log-store).
    await deleteFromSheet(tester, context, ref, 'k-ops');
    expect(dialog(), findsOneWidget);
    expect(find.descendant(of: dialog(), matching: find.text(l10n.homeDeleteIdentityUsedBy(5))), findsOneWidget);
    expect(bulletsShown(tester), ['db-primary', 'hypervisor-b', 'mac-studio', 'web-01', 'web-02']);
    for (final name in bulletsShown(tester)) {
      expect(
        find.descendant(of: dialog(), matching: find.text(name)),
        findsOneWidget,
        reason: name,
      );
    }
    await tester.tap(find.descendant(of: dialog(), matching: find.text(l10n.cancel)));
    await settleQuickWins(tester);

    // Three more hosts sign in with it: five by name, then "and 3 more hosts".
    // (Written in the test's own time, the database answering as frames
    // pass: written from outside it, the write waited for them forever.)
    final written = db.batch(
      (b) => b.insertAll(db.connections, [
        for (final (id, label) in [('x1', 'cache-01'), ('x2', 'build-runner'), ('x3', 'vpn-gateway')])
          ConnectionsCompanion.insert(
            id: id,
            label: label,
            host: '192.168.10.9$id',
            identityId: const Value('k-ops'),
            createdAt: DateTime(2026),
            updatedAt: DateTime(2026),
          ),
      ]),
    );
    await settleQuickWins(tester);
    await written;
    await settleQuickWins(tester);
    await deleteFromSheet(tester, context, ref, 'k-ops');
    expect(find.descendant(of: dialog(), matching: find.text(l10n.homeDeleteIdentityUsedBy(8))), findsOneWidget);
    expect(bulletsShown(tester), [
      'build-runner',
      'cache-01',
      'db-primary',
      'hypervisor-b',
      'mac-studio',
      'and 3 more hosts',
    ]);
    expect(find.descendant(of: dialog(), matching: find.text('and 3 more hosts')), findsOneWidget);
    await tester.tap(find.descendant(of: dialog(), matching: find.text(l10n.cancel)));
    await settleQuickWins(tester);

    // A key no host uses: said so, and no list.
    await deleteFromSheet(tester, context, ref, 'k-ci');
    expect(find.descendant(of: dialog(), matching: find.text(l10n.homeDeleteIdentityUnused)), findsOneWidget);
    expect(bulletsShown(tester), isEmpty);
    await tester.tap(find.descendant(of: dialog(), matching: find.text(l10n.cancel)));
    await unpumpQuickWins(tester);
  });

  phone('the list of keys: Delete names the hosts too', (tester) async {
    await pumpQuickWins(tester, const IdentityListScreen(), quickWinsPhone);
    await tester.longPress(find.text('Ops laptop'));
    await settleQuickWins(tester);
    await tester.tap(find.widgetWithText(ListTile, l10n.delete).last);
    await settleQuickWins(tester);
    expect(find.descendant(of: dialog(), matching: find.text(l10n.identityListDeleteUsageMessage(5))), findsOneWidget);
    expect(bulletsShown(tester), ['db-primary', 'hypervisor-b', 'mac-studio', 'web-01', 'web-02']);
    await tester.tap(find.descendant(of: dialog(), matching: find.text(l10n.cancel)));
    await unpumpQuickWins(tester);
  });
}
