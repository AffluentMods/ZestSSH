import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/spaces.dart' show kOrchardsEnabled;
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart' show orchardDisplayName;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/ui/screens/tree/manage_tree_screen.dart';

/// Whether the account has Juiced, as the app holds it.
class _Juiced extends StateNotifier<bool> implements CloudSyncStatusNotifier {
  _Juiced(super.state);

  @override
  Future<void> refresh() async {}

  @override
  Future<bool> forceRefresh() async => state;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The personal space's page (it was Manage Tree before a rename).
/// Its sync row follows whether sync is set up on this
/// device, with any storage: it said "Sync requires Juiced" to everyone
/// syncing with storage of their own, and showed a Juiced badge. Its row
/// for working with others said "Coming with Teams in 3.0": where teams are
/// built in, it makes one now, and nowhere else is it shown.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  Future<void> show(WidgetTester tester, {required bool syncOn, bool juiced = false}) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        treeDatabaseProvider.overrideWithValue(db),
        currentUserProvider.overrideWith((_) => const UserProfile(uid: 'u1', email: 'alex@example.com')),
        connectionsWithDetailsProvider.overrideWith((ref) => Stream.value(const [])),
        isCloudSyncProvider.overrideWith((ref) => _Juiced(juiced)),
        syncIsActiveProvider.overrideWith((ref) async => syncOn),
        recordingModeProvider.overrideWith((ref) => false),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: ManageTreeScreen(),
      ),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  String words(WidgetTester tester) =>
      tester.widgetList<Text>(find.byType(Text)).map((t) => t.data ?? t.textSpan?.toPlainText() ?? '').join('\n');

  testWidgets('sync with storage of your own and no Juiced: the row sends the changes, and names no Juiced',
      (tester) async {
    await show(tester, syncOn: true);
    expect(find.text(l10n.manageTreeTitle), findsOneWidget);
    expect(find.text(l10n.manageTreeForceSyncActive), findsOneWidget);
    expect(words(tester), isNot(contains('Juiced')));
    expect(words(tester), isNot(contains('Tree')));
  });

  testWidgets('sync not set up: said where it is set up, that it is free, and tapping says the same',
      (tester) async {
    await show(tester, syncOn: false, juiced: true);
    expect(find.text(l10n.manageTreeForceSyncUpsell), findsOneWidget);
    expect(words(tester), isNot(contains('Juiced')));
    await tester.tap(find.text(l10n.manageTreeForceSyncNow));
    await tester.pump();
    // A notice: on the screen, or in the notification center where the desktop puts it.
    final container = ProviderScope.containerOf(tester.element(find.byType(ManageTreeScreen)));
    final told = find.text(l10n.manageTreeSyncRequiresJuiced).evaluate().isNotEmpty ||
        container.read(notificationCenterProvider).history.any(
            (n) => n.title == l10n.manageTreeSyncRequiresJuiced || n.body == l10n.manageTreeSyncRequiresJuiced);
    expect(told, isTrue);
    // The notice goes by itself.
    await tester.pump(const Duration(seconds: 16));
    expect(l10n.manageTreeSyncRequiresJuiced, isNot(contains('Juiced')));
  });

  testWidgets('working with other people: a team where teams are built in, and no "coming in 3.0" anywhere',
      (tester) async {
    await show(tester, syncOn: true);
    expect(find.byKey(const ValueKey('manage-tree-invite')), kOrchardsEnabled ? findsOneWidget : findsNothing);
    expect(words(tester), isNot(contains('3.0')));
    if (!kOrchardsEnabled) return;
    expect(find.text(l10n.manageTreeInviteComingSoon), findsOneWidget);
    // It makes a team: signed in, its dialog opens once the team keys are
    // ready (a guest signs in first: test/ui/new_people_test.dart).
    await tester.tap(find.byKey(const ValueKey('manage-tree-invite')));
    for (var i = 0; i < 10 && find.text(l10n.orchardCreateTitle).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    final container = ProviderScope.containerOf(tester.element(find.byType(ManageTreeScreen)));
    bool said(String words) =>
        find.text(words).evaluate().isNotEmpty ||
        container.read(notificationCenterProvider).history.any((n) => n.title == words || n.body == words);
    // Here, with no ZestSSH Cloud to make the keys with, it says so plainly.
    expect(said(l10n.orchardCreateTitle) || said(l10n.joinNotReady), isTrue);
    expect(said(l10n.orchardErrorSignedOut), isFalse);
    await tester.pump(const Duration(seconds: 16));
  });

  test('the words: the personal space by its new name, and Juiced sold for what it is', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final t = lookupAppLocalizations(locale);
      for (final s in [
        t.manageTreeTitle,
        t.treeSelectorMyTree,
        t.treeSelectorNamedTree('Alex'),
        t.manageTreeInviteComingSoon,
        t.manageTreeForceSyncUpsell,
        t.manageTreeSyncRequiresJuiced,
        t.deskUpgJuicedFeatureShare,
        t.deskUpgJuicedOfferFeatureShareRoles,
      ]) {
        expect(s, isNot(contains('3.0')), reason: '$locale: $s');
        expect(s, isNot(contains('Juiced')), reason: '$locale: $s');
      }
      expect(t.orchardNamed('Acme'), 'Acme', reason: '$locale');
    }
    expect(l10n.treeSelectorMyTree, 'Personal');
    // A team is shown by its own name.
    expect(orchardDisplayName('  Acme ', l10n), 'Acme');
    expect(orchardDisplayName('Acme Orchard', l10n), 'Acme Orchard');
    expect(orchardDisplayName(null, l10n), l10n.orchardUnnamed);
    expect(l10n.orchardUnnamed, 'Unnamed team');
    // Squeezed is sold for what it unlocks: split terminals, workspaces, hardware keys, agent forwarding, widgets
    // and transcripts are free, and are not listed.
    expect([l10n.deskUpgSqueezedFeatureSplit, l10n.deskUpgSqueezedFeatureTokens, l10n.deskUpgSqueezedMore], [
      'Command history, with suggestions as you type',
      'Background monitoring for every host (5 on Free)',
      '+ voice input on phones, and every future Pro feature',
    ]);
    // Juiced is ZestSSH Cloud's storage, not sharing.
    for (final s in [l10n.deskUpgJuicedFeatureSync, l10n.deskUpgJuicedFeatureShare, l10n.deskUpgJuicedFeatureApproval,
      l10n.deskUpgJuicedOfferFeatureShareRoles, l10n.deskUpgJuicedOfferTagline]) {
      expect(s.toLowerCase(), isNot(anyOf(contains('share'), contains('tree'), contains('approval'))), reason: s);
    }
    expect(l10n.treeSelectorNamedTree('Alex'), 'Personal');
  });
}
