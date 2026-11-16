import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart' show BiometricType;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/onboarding/onboarding_screen.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/services/security_lock_service.dart';
import 'package:zestssh/services/vault_slot_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/security/security_lock_screen.dart';
import 'package:zestssh/ui/widgets/window_bar.dart';
import 'package:zestssh/utils/platform_utils.dart';

import 'shots_util.dart';

/// A lock with a PIN and the system's unlock; its prompt, once asked for, is
/// still up when the picture is taken.
class _Lock implements SecurityLockService {
  _Lock(this.method);

  final SecurityLockMethod method;

  @override
  bool get isLockedOut => false;
  @override
  int get remainingLockoutSeconds => 0;
  @override
  int get failedAttempts => 0;
  @override
  int get maxAttempts => 10;
  @override
  Future<bool> hasPinConfigured() async => true;
  @override
  Future<SecurityLockMethod> getLockMethod() async => method;
  @override
  Future<List<BiometricType>> getAvailableBiometrics() async => const [BiometricType.face];
  @override
  Future<BiometricAuthOutcome> authenticateWithBiometric({String? reason}) => Completer<BiometricAuthOutcome>().future;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Vault implements VaultSlotService {
  @override
  Future<bool> isEnabled() async => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Locked by "Lock when idle" after 5 minutes, as the mockup shows it.
class _LockedWhileIdle extends AppLockNotifier {
  _LockedWhileIdle(super.ref);

  @override
  AppLockReason get why => const AppLockReason(AppLockCause.idle, 5);
}

/// The screens a computer shows without the shell, with the window's controls
/// and the lock screen on a phone (4.0). Pictures
/// land in build/shots/window-bar-*.png and lock-phone.png.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => AppColors.applyTheme(BuiltInThemes.getById('default_dark').colorScheme));

  Future<void> shot(
    WidgetTester tester,
    String name,
    Widget screen, {
    String themeId = 'default_dark',
    Size size = const Size(1200, 800),
    double pixelRatio = 1,
    SecurityLockMethod method = SecurityLockMethod.pin,
    bool windowBar = true,
    FakeViewPadding padding = FakeViewPadding.zero,
    Future<void> Function()? then,
  }) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), (call) async => false);
    await tester.runAsync(loadShotFonts);
    // The app's own theme (it was a plain ThemeData.dark, whose purple tint was
    // the test's): Ember by default, as a new install has it.
    final theme = BuiltInThemes.getById(themeId);
    AppColors.applyTheme(theme.colorScheme);
    SharedPreferences.setMockInitialValues({'security_lock_enabled': true});
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = size * pixelRatio;
    tester.view.devicePixelRatio = pixelRatio;
    tester.view.padding = padding;
    tester.view.viewPadding = padding;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        securityLockServiceProvider.overrideWithValue(_Lock(method)),
        vaultSlotServiceProvider.overrideWithValue(_Vault()),
        isAppLockedProvider.overrideWith(_LockedWhileIdle.new),
      ],
      child: RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          theme: theme.toThemeData(),
          home: windowBar ? WindowBarOver(shown: true, child: screen) : screen,
        ),
      ),
    ));
    // The app's mark, decoded before the picture is taken.
    await tester.runAsync(() => precacheImage(const AssetImage('assets/ZestSSH.png'), tester.element(find.byType(MaterialApp))));
    await tester.pump(const Duration(milliseconds: 300));
    if (then != null) await then();
    await tester.pump(const Duration(milliseconds: 300));
    realShadows();
    await tester.pump();
    await saveShot(tester, key, name, pixelRatio: pixelRatio);
    plainShadows();
    if (windowBar) expect(find.byType(WindowControls), findsOneWidget);
  }

  testWidgets('the lock screen', (tester) async {
    // A Windows computer with Windows Hello, two digits typed, as
    // designed.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    // The caret drawn, as the mockup has it (it blinks in the app).
    EditableText.debugDeterministicCursor = true;
    try {
      await shot(tester, 'window-bar-lock', const SecurityLockScreen(), method: SecurityLockMethod.both, then: () async {
        await tester.enterText(find.byType(TextField), '12');
        // The arrow turns orange over the next frames; the caret shows for half a
        // second after each key, and the picture is taken in it.
        await tester.pump(const Duration(milliseconds: 100));
      });
    } finally {
      debugDefaultTargetPlatformOverride = null;
      EditableText.debugDeterministicCursor = false;
    }
  }, skip: !shotsEnabled);

  testWidgets('the lock screen on a phone', (tester) async {
    // An iPhone with Face ID, its prompt up, two digits typed on the app's own
    // pad, in Graphite, as designed.
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    debugTouchLayout = true;
    try {
      await shot(
        tester,
        'lock-phone',
        // Still: the glyph does not pulse while the prompt is up.
        Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: const SecurityLockScreen(),
          ),
        ),
        themeId: 'graphite',
        size: const Size(390, 844),
        pixelRatio: 2,
        method: SecurityLockMethod.both,
        windowBar: false,
        // An iPhone's status bar and home indicator.
        padding: const FakeViewPadding(top: 47 * 2, bottom: 34 * 2),
        then: () async {
          await tester.tap(find.byKey(const ValueKey('lock-key-1')));
          await tester.pump();
          await tester.tap(find.byKey(const ValueKey('lock-key-2')));
          // The keys' ink fades before the picture.
          for (var i = 0; i < 10; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
        },
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
      debugTouchLayout = null;
    }
  }, skip: !shotsEnabled);

  testWidgets('the welcome', (tester) async {
    await shot(tester, 'window-bar-welcome', const OnboardingScreen());
  }, skip: !shotsEnabled);
}
