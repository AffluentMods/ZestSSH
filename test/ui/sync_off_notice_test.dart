import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/ui/widgets/sync_off_notice.dart';

/// A personal host saved while sync is off is said to be on this device only
/// on saving; never with sync on, never for a team's
/// hosts, and never again once asked not to.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  Future<(SettingsService, List<bool>)> open(WidgetTester tester, {bool syncOn = false, bool team = false}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final answers = <bool>[];
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      syncOffNoticeEnabledProvider.overrideWithValue(true),
      syncIsActiveProvider.overrideWith((ref) async => syncOn),
    ]);
    addTearDown(container.dispose);
    if (team) container.read(activeSpaceProvider.notifier).state = const OrchardSpace('o1');
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () async => answers.add(await maybeShowSyncOffNotice(context, ref)),
              child: const Text('saved'),
            ),
          ),
        ),
      ),
    ));
    return (container.read(settingsServiceProvider), answers);
  }

  testWidgets('sync off: said, Set up sync answers yes; Not now with "Don\'t show this again" ends it', (tester) async {
    final (settings, answers) = await open(tester);
    await tester.tap(find.text('saved'));
    await tester.pumpAndSettle();
    expect(find.text(l10n.syncOffNoticeTitle), findsOneWidget);
    await tester.tap(find.text(l10n.syncOffNoticeSetUp));
    await tester.pumpAndSettle();
    expect(answers, [true]);

    await tester.tap(find.text('saved'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sync-off-notice-hide')));
    await tester.pump();
    await tester.tap(find.text(l10n.syncOffNoticeNotNow));
    await tester.pumpAndSettle();
    expect(answers, [true, false]);
    expect(settings.syncOffNoticeHidden, isTrue);

    await tester.tap(find.text('saved'));
    await tester.pumpAndSettle();
    expect(find.text(l10n.syncOffNoticeTitle), findsNothing, reason: 'asked not to be told again');
  });

  testWidgets('nothing with sync on, or for a team host', (tester) async {
    await open(tester, syncOn: true);
    await tester.tap(find.text('saved'));
    await tester.pumpAndSettle();
    expect(find.text(l10n.syncOffNoticeTitle), findsNothing);

    await open(tester, team: true);
    await tester.tap(find.text('saved'));
    await tester.pumpAndSettle();
    expect(find.text(l10n.syncOffNoticeTitle), findsNothing);
  });
}
