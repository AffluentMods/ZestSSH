import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/onboarding/onboarding_screen.dart';
import 'package:zestssh/features/orchards/crypto/join_code_crypto.dart' show joinCodeFromText;
import 'package:zestssh/features/orchards/widgets/join_team.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/desktop/widgets/account_attention.dart' show accountSetupNeedsAttentionProvider;
import 'package:zestssh/ui/screens/desktop/widgets/narrow_sidebar.dart';
import 'package:zestssh/ui/screens/profile/account_sign_in.dart' show debugSignsInOnDevice;

import 'shots_util.dart';

// Pictures of what new people see: the welcome on a
// computer and a phone, Join a team not signed in, and the bottom of the rail
// for a guest and for a signed-in Free account. Off unless asked for:
//
//   flutter test --dart-define=ZEST_SHOTS=true test/visual/new_people_shots_test.dart

class _Off extends StateNotifier<bool> implements ProStatusNotifier, CloudSyncStatusNotifier {
  _Off() : super(false);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Future<void> shot(WidgetTester tester, String name, Size size, Widget child, {UserProfile? user}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final theme = BuiltInThemes.getById('default_dark');
    AppColors.applyTheme(theme.colorScheme);
    final key = GlobalKey();
    await tester.pumpWidget(ProviderScope(
      key: UniqueKey(),
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        authStateProvider.overrideWith((_) => const Stream.empty()),
        desktopSessionProvider.overrideWith((_) => user),
        isProProvider.overrideWith((_) => _Off()),
        isCloudSyncProvider.overrideWith((_) => _Off()),
        accountSetupNeedsAttentionProvider.overrideWith((_) async => false),
      ],
      child: RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme.toThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: child),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    // The app's logo decoded before the picture is taken (the first picture
    // drew the welcome without it).
    await tester.runAsync(() => precacheImage(const AssetImage('assets/ZestSSH.png'), key.currentContext!));
    await tester.pumpAndSettle();
    await saveShot(tester, key, name);
  }

  const alex = UserProfile(uid: 'uid-alex', email: 'alex@example.com', displayName: 'Alex Morgan');
  final rail = Row(children: [
    NarrowSidebar(activeSection: NavSection.hosts, onSectionChanged: (_) {}),
    const Expanded(child: SizedBox()),
  ]);

  testWidgets('new people', (tester) async {
    await tester.runAsync(loadShotFonts);
    await shot(tester, 'welcome_computer', const Size(1280, 800), const OnboardingScreen());
    // A phone's welcome as a phone draws it, an iPhone's (the test runs on
    // a computer, which drew a computer's welcome at a phone's size): its
    // words, and its sign-in in the app.
    OnboardingScreen.debugPhone = true;
    debugSignsInOnDevice = true;
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await shot(tester, 'welcome_phone', const Size(390, 844), const OnboardingScreen());
    debugDefaultTargetPlatformOverride = null;
    debugSignsInOnDevice = null;
    OnboardingScreen.debugPhone = null;
    await shot(tester, 'join_guest', const Size(720, 640),
        Center(child: JoinTeamDialog(initialCode: joinCodeFromText('ZEST-7KQ2-ABCD-EFGH-JKLM-NP23'), fromLink: true)));
    await shot(tester, 'rail_guest', const Size(420, 640), rail);
    await shot(tester, 'rail_free', const Size(420, 640), rail, user: alex);
  }, skip: !shotsEnabled);
}
