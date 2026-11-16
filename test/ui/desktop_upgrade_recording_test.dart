import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/ui/screens/profile/sso_sign_in.dart';
import 'package:zestssh/ui/screens/purchase/desktop_upgrade_view.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/redactor.dart';

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro(super.owned);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Sync extends StateNotifier<bool> implements CloudSyncStatusNotifier {
  _Sync(super.owned);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A computer's upgrade page, for one who owns both, masks the account and
/// this machine's name while the screen is recorded (3.0).
/// It showed the account's address and the machine's name as they are, on a
/// recording of the screen too, where the account page masked both. So did
/// the notice that an address already has an account.
void main() {
  const email = 'robin@example.com';
  final machine = Platform.localHostname.trim();

  tearDown(() => Redactor.instance
    ..clearNames()
    ..enabled = false);

  Future<void> pump(WidgetTester tester, {required bool recording}) async {
    tester.view.physicalSize = const Size(1400, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'recording_mode_enabled': recording});
    final prefs = await SharedPreferences.getInstance();
    Redactor.instance
      ..clearNames()
      ..enabled = recording
      ..level = RedactLevel.layout;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        isProProvider.overrideWith((ref) => _Pro(true)),
        isCloudSyncProvider.overrideWith((ref) => _Sync(true)),
        currentUserProvider.overrideWithValue(const UserProfile(uid: 'u-robin', email: email)),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: DesktopUpgradeView()),
      ),
    ));
    await tester.pump(const Duration(seconds: 2));
  }

  Iterable<String> shown(WidgetTester tester) =>
      tester.widgetList<Text>(find.byType(Text)).map((t) => t.data ?? t.textSpan?.toPlainText() ?? '');

  testWidgets('while the screen is recorded: no address of the account, and no name of this machine', (tester) async {
    await pump(tester, recording: true);
    expect(shown(tester).where((t) => t.contains(email)), isEmpty);
    if (machine.isNotEmpty) expect(shown(tester).where((t) => t.contains(machine)), isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });

  testWidgets('the notice that an address has an account: the address masked while recorded', (tester) async {
    for (final recording in [true, false]) {
      SharedPreferences.setMockInitialValues({'recording_mode_enabled': recording});
      Redactor.instance
        ..clearNames()
        ..enabled = recording
        ..level = RedactLevel.layout;
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showAddressHasAccount(context, email),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final body = tester.widget<ZestConfirmDialog>(find.byType(ZestConfirmDialog)).body;
      expect(body.contains(email), !recording, reason: recording ? 'recorded: masked' : 'not recorded: as it is');
      // Got it: what the button is (it said OK; the dialog rules, 3.4).
      await tester.tap(find.text(lookupAppLocalizations(const Locale('en')).desktopGotIt));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('not recorded: the account and this machine as they are', (tester) async {
    await pump(tester, recording: false);
    expect(shown(tester).where((t) => t.contains(email)), isNotEmpty);
    if (machine.isNotEmpty) expect(shown(tester).where((t) => t.contains(machine)), isNotEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });
}
