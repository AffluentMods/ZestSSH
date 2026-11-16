import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/features/onboarding/onboarding_screen.dart';
import 'package:zestssh/features/orchards/crypto/join_code_crypto.dart' show joinCodeFromText;
import 'package:zestssh/features/orchards/widgets/join_team.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/ui/screens/desktop/widgets/account_attention.dart' show accountSetupNeedsAttentionProvider;
import 'package:zestssh/ui/screens/desktop/widgets/narrow_sidebar.dart';
import 'package:zestssh/ui/screens/profile/account_sign_in.dart' show debugSignsInOnDevice;
import '../a11y/a11y_checks.dart';

// New people (as designed): a new install
// said nothing of signing up or signing in; a guest
// joining a team was told "Sign in first" with nothing to press; and Upgrade,
// a word under the name inside the account's row at the bottom left, opened
// pricing on a click a little low on the name.

class _Paid extends StateNotifier<bool> implements ProStatusNotifier {
  _Paid(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Cloud extends StateNotifier<bool> implements CloudSyncStatusNotifier {
  _Cloud(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _alex = UserProfile(uid: 'uid-alex', email: 'alex@example.com', displayName: 'Alex Morgan');

Finder _key(String k) => find.byKey(ValueKey(k));

Future<SharedPreferences> _prefs() async {
  SharedPreferences.setMockInitialValues({});
  return SharedPreferences.getInstance();
}

/// [child] in the app, signed in as [user] (null: a guest), Squeezed where
/// [pro], in a window [size] big.
Future<ProviderContainer> _pump(WidgetTester tester, Widget child,
    {UserProfile? user, bool pro = false, Size size = const Size(1280, 860)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final prefs = await _prefs();
  final scope = ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      authStateProvider.overrideWith((_) => const Stream.empty()),
      desktopSessionProvider.overrideWith((_) => user),
      isProProvider.overrideWith((_) => _Paid(pro)),
      isCloudSyncProvider.overrideWith((_) => _Cloud(false)),
      accountSetupNeedsAttentionProvider.overrideWith((_) async => false),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    ),
  );
  await tester.pumpWidget(scope);
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byWidget(child)));
}

const _rail = Row(
  children: [
    NarrowSidebar(activeSection: NavSection.hosts, onSectionChanged: _ignore),
    Expanded(child: SizedBox()),
  ],
);

void _ignore(NavSection _) {}

void main() {
  group('the bottom left of the rail', () {
    testWidgets('a guest: Guest, on this computer only, and a Sign in button of its own; no Upgrade', (tester) async {
      await _pump(tester, _rail);
      final l10n = AppLocalizations.of(tester.element(find.byType(NarrowSidebar)))!;
      expect(find.descendant(of: _key('rail-profile'), matching: find.text(l10n.narrowSidebarGuest)), findsOneWidget);
      expect(find.descendant(of: _key('rail-profile'), matching: find.text(l10n.railGuestLocal)), findsOneWidget);
      expect(_key('rail-sign-in'), findsOneWidget);
      expect(_key('rail-upgrade'), findsNothing, reason: 'buying needs an account');
    });

    testWidgets('signed in on Free: Upgrade is a row of its own, and the account row says Free with no Upgrade in it',
        (tester) async {
      await _pump(tester, _rail, user: _alex);
      final l10n = AppLocalizations.of(tester.element(find.byType(NarrowSidebar)))!;
      expect(_key('rail-upgrade'), findsOneWidget);
      expect(find.descendant(of: _key('rail-profile'), matching: find.textContaining(l10n.narrowSidebarUpgradeRow)),
          findsNothing);
      expect(find.descendant(of: _key('rail-profile'), matching: find.text(l10n.narrowSidebarTierFree)), findsOneWidget);
      expect(_key('rail-sign-in'), findsNothing);
      // Apart: Upgrade ends above where the account's row begins.
      expect(tester.getBottomLeft(_key('rail-upgrade')).dy, lessThan(tester.getTopLeft(_key('rail-profile')).dy));
    });

    testWidgets('signed in with Squeezed: no Upgrade at all', (tester) async {
      await _pump(tester, _rail, user: _alex, pro: true);
      expect(_key('rail-upgrade'), findsNothing);
      expect(_key('rail-sign-in'), findsNothing);
    });
  });

  group('Join a team, not signed in', () {
    const code = 'ZEST-7KQ2-ABCD-EFGH-JKLM-NP23';

    testWidgets('the code is kept and the sign-in is in the dialog; signed in, it is the code again', (tester) async {
      final container = await _pump(tester, JoinTeamDialog(initialCode: joinCodeFromText(code), fromLink: true));
      final l10n = AppLocalizations.of(tester.element(find.byType(JoinTeamDialog)))!;
      expect(find.text(l10n.joinNeedsAccount), findsOneWidget);
      expect(_key('join-code-kept'), findsOneWidget);
      expect(tester.widget<EditableText>(find.descendant(of: _key('join-code-field'), matching: find.byType(EditableText)))
          .controller
          .text, code);
      // A computer signs in in the browser: Sign in, and Create an account.
      expect(_key('join-sign-in'), findsOneWidget);
      expect(_key('join-create-account'), findsOneWidget);
      expect(_key('join-continue'), findsNothing, reason: 'looking up the code needs an account');

      container.read(desktopSessionProvider.notifier).state = _alex;
      await tester.pumpAndSettle();
      expect(_key('join-code-kept'), findsNothing);
      expect(_key('join-continue'), findsOneWidget);
    });
  });

  group('the welcome', () {
    tearDown(() {
      OnboardingScreen.debugPhone = null;
      OnboardingScreen.debugOpenPage = null;
      debugSignsInOnDevice = null;
    });

    // The 4.0 accessibility pass: the welcome on a computer
    // holds to the checks every screen of the pass does: every control a
    // screen reader can press has a name, a pointer's target is 32 square,
    // and its main button and its words read.
    testWidgets('on a computer: names, targets (the 4.0 accessibility pass)', (tester) async {
      final handle = tester.ensureSemantics();
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await _pump(tester, const OnboardingScreen());
        // (Its colours are the theme's, checked for every theme in
        // theme_contrast_test; it is drawn here without the app's theme.)
        expect(await a11yCheck(tester, computer: true, contrast: false, where: 'welcome'), isEmpty);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        handle.dispose();
      }
    });

    testWidgets('a new install not signed in opens at it: Start using ZestSSH is the main button and Sign in the second, '
        'with no Create an account; going on with no account goes on to getting connected', (tester) async {
      await _pump(tester, const OnboardingScreen());
      final l10n = AppLocalizations.of(tester.element(find.byType(OnboardingScreen)))!;
      expect(_key('welcome'), findsOneWidget);
      expect(find.text(l10n.welcomeTitle), findsOneWidget);
      expect(tester.widget(_key('welcome-start')), isA<FilledButton>());
      expect(tester.widget(_key('welcome-sign-in')), isA<OutlinedButton>());
      expect(tester.getTopLeft(_key('welcome-start')).dy, lessThan(tester.getTopLeft(_key('welcome-sign-in')).dy),
          reason: 'going on with no account comes first');
      expect(_key('welcome-create'), findsNothing);
      expect(find.text(l10n.welcomeCreateAccount), findsNothing);
      // A computer: where everything stays, and where to sign in later; the
      // browser signs in, as its icon says too.
      expect(find.text(l10n.welcomeGuestComputer), findsOneWidget);
      expect(find.text(l10n.welcomeBrowserNote), findsOneWidget);
      expect(find.descendant(of: _key('welcome-sign-in'), matching: find.byIcon(LucideIcons.externalLink)), findsOneWidget);
      await tester.tap(_key('welcome-start'));
      await tester.pumpAndSettle();
      expect(_key('welcome'), findsNothing);
      expect(find.text(l10n.firstRunTitle), findsOneWidget);
    });

    testWidgets("its words: free to use with no account, the app's ticks, sync through one's own storage free, and "
        "hosted sync Juiced's; nothing of a free account's sync", (tester) async {
      await _pump(tester, const OnboardingScreen());
      final l10n = AppLocalizations.of(tester.element(find.byType(OnboardingScreen)))!;
      expect(find.text('${l10n.welcomeLeadWhat}\n${l10n.welcomeLeadFree}'), findsOneWidget);
      for (final words in [
        l10n.welcomeTickHosts,
        l10n.welcomeTickKeysComputer,
        l10n.welcomeTickSync,
        l10n.welcomeJuicedLine,
        l10n.welcomeWhatIsJuiced,
      ]) {
        expect(find.text(words), findsOneWidget, reason: words);
      }
      expect(l10n.welcomeTickSync, 'Sync free through your own storage, and sign in later to join a team');
      expect(find.text(l10n.welcomeTickKeysDevice), findsNothing, reason: "a computer's words");
      for (final e in find.byType(Text).evaluate()) {
        final words = ((e.widget as Text).data ?? '').toLowerCase();
        expect(words, isNot(contains('free account')), reason: words);
        expect(words, isNot(contains('on all your devices')), reason: words);
      }
    });

    testWidgets('What is Juiced? is a link to the plans page of the website', (tester) async {
      final opened = <Uri>[];
      OnboardingScreen.debugOpenPage = (page) async => opened.add(page);
      await _pump(tester, const OnboardingScreen());
      expect(tester.getSemantics(_key('welcome-what-is-juiced')), isSemantics(isLink: true));
      await tester.tap(_key('welcome-what-is-juiced'));
      await tester.pump();
      expect(opened, [Uri.parse('https://zestssh.com/pricing/plans')]);
    });

    testWidgets("on a phone: a device's words, the buttons at the foot in a thumb's reach, 48 high, and Sign in "
        "with the app's own ways, Create an account among them", (tester) async {
      OnboardingScreen.debugPhone = true;
      debugSignsInOnDevice = true;
      await _pump(tester, const OnboardingScreen(), size: const Size(390, 844));
      final l10n = AppLocalizations.of(tester.element(find.byType(OnboardingScreen)))!;
      expect(find.text(l10n.welcomeTickKeysDevice), findsOneWidget);
      expect(find.text(l10n.welcomeGuestPhone), findsOneWidget);
      expect(find.text(l10n.welcomeSignInWays), findsOneWidget, reason: "not an Apple device's: Google or email");
      expect(find.text(l10n.welcomeBrowserNote), findsNothing);
      expect(find.byIcon(LucideIcons.externalLink), findsNothing);
      // The title at the top, what to do in the lower half.
      expect(tester.getTopLeft(_key('welcome-start')).dy, greaterThan(844 / 2));
      expect(tester.getBottomLeft(find.text(l10n.welcomeTitle)).dy, lessThan(tester.getTopLeft(_key('welcome-start')).dy));
      for (final k in ['welcome-start', 'welcome-sign-in', 'welcome-what-is-juiced']) {
        expect(tester.getSize(_key(k)).height, greaterThanOrEqualTo(48), reason: k);
      }
      await tester.tap(_key('welcome-sign-in'));
      await tester.pumpAndSettle();
      expect(_key('sign-in-ways'), findsOneWidget);
      expect(_key('sign-in-way-email'), findsOneWidget);
      await tester.tap(find.text(l10n.cancel));
      await tester.pumpAndSettle();
      expect(_key('welcome'), findsOneWidget, reason: 'nothing picked: still at the welcome');
    });

    // On a device run, a large tablet has the computer's
    // shell (4.0), the account at the rail's foot and no More tab,
    // yet its welcome said to sign in from More.
    testWidgets("a tablet with the computer's shell: sign in from the bottom left, not from More", (tester) async {
      OnboardingScreen.debugPhone = true;
      debugSignsInOnDevice = true;
      await _pump(tester, const OnboardingScreen(), size: const Size(1366, 1024));
      final l10n = AppLocalizations.of(tester.element(find.byType(OnboardingScreen)))!;
      expect(find.text(l10n.welcomeGuestTabletShell), findsOneWidget);
      expect(find.text(l10n.welcomeGuestPhone), findsNothing);
      expect(find.text(l10n.welcomeGuestComputer), findsNothing, reason: 'a device, not a computer');
      // Turned upright, an iPad Pro 12.9 still has the shell; a tablet 800
      // wide has the phone's tabs, More among them.
      tester.view.physicalSize = const Size(1024, 1366);
      await tester.pumpAndSettle();
      expect(find.text(l10n.welcomeGuestTabletShell), findsOneWidget);
      tester.view.physicalSize = const Size(800, 1280);
      await tester.pumpAndSettle();
      expect(find.text(l10n.welcomeGuestPhone), findsOneWidget);
      expect(find.text(l10n.welcomeGuestTabletShell), findsNothing);
    });

    testWidgets("an iPhone's: Apple named first among the ways", (tester) async {
      OnboardingScreen.debugPhone = true;
      debugSignsInOnDevice = true;
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await _pump(tester, const OnboardingScreen(), size: const Size(390, 844));
      final l10n = AppLocalizations.of(tester.element(find.byType(OnboardingScreen)))!;
      expect(find.text(l10n.welcomeSignInWaysApple), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('signed in already: straight to getting connected', (tester) async {
      await _pump(tester, const OnboardingScreen(), user: _alex);
      final l10n = AppLocalizations.of(tester.element(find.byType(OnboardingScreen)))!;
      expect(_key('welcome'), findsNothing);
      expect(find.text(l10n.firstRunTitle), findsOneWidget);
    });
  });

  // A build made without ZEST_OFFICIAL=true (found in a review): it signs nobody in
  // and sells nothing, so it offers neither.
  group('a community build', () {
    setUp(() {
      debugZestOfficial = false;
      addTearDown(() => debugZestOfficial = true);
    });
    tearDown(() {
      OnboardingScreen.debugPhone = null;
      debugSignsInOnDevice = null;
    });

    testWidgets('the rail: the account row, with no Sign in, no Upgrade and no Discord', (tester) async {
      await _pump(tester, _rail);
      final l10n = AppLocalizations.of(tester.element(find.byType(NarrowSidebar)))!;
      expect(find.descendant(of: _key('rail-profile'), matching: find.text(l10n.railGuestLocal)), findsOneWidget);
      expect(_key('rail-sign-in'), findsNothing);
      expect(_key('rail-upgrade'), findsNothing);
      expect(_key('rail-discord'), findsNothing);
      expect(find.byTooltip(l10n.narrowSidebarJoinDiscord), findsNothing);
    });

    testWidgets('the welcome on a computer: Start using ZestSSH alone, where things stay, and no Sign in or plans',
        (tester) async {
      await _pump(tester, const OnboardingScreen());
      final l10n = AppLocalizations.of(tester.element(find.byType(OnboardingScreen)))!;
      expect(_key('welcome-start'), findsOneWidget);
      expect(find.text(l10n.welcomeStaysHere), findsOneWidget);
      expect(find.text(l10n.welcomeGuestComputer), findsNothing);
      for (final k in ['welcome-sign-in', 'welcome-sign-in-note', 'welcome-what-is-juiced']) {
        expect(_key(k), findsNothing, reason: k);
      }
      expect(find.text(l10n.profileOrDivider), findsNothing);
    });

    testWidgets('the welcome on a phone: the same, and going on goes on to getting connected', (tester) async {
      OnboardingScreen.debugPhone = true;
      debugSignsInOnDevice = true;
      await _pump(tester, const OnboardingScreen(), size: const Size(390, 844));
      final l10n = AppLocalizations.of(tester.element(find.byType(OnboardingScreen)))!;
      expect(find.text(l10n.welcomeStaysHere), findsOneWidget);
      for (final k in ['welcome-sign-in', 'welcome-what-is-juiced']) {
        expect(_key(k), findsNothing, reason: k);
      }
      await tester.tap(_key('welcome-start'));
      await tester.pumpAndSettle();
      expect(_key('welcome'), findsNothing);
      expect(find.text(l10n.firstRunTitle), findsOneWidget);
    });
  });
}
