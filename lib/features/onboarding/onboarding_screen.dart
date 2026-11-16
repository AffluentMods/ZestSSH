import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/features/onboarding/data/onboarding_import.dart';
import 'package:zestssh/features/onboarding/data/ssh_config_source.dart';
import 'package:zestssh/features/onboarding/widgets/get_connected_options.dart';
import 'package:zestssh/features/onboarding/widgets/lan_scan_view.dart';
import 'package:zestssh/features/onboarding/widgets/ssh_config_review.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/profile/account_sign_in.dart';
import 'package:zestssh/ui/widgets/window_bar.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/utils/platform_utils.dart' show isLargeScreen, isMobilePlatform;
import 'package:zestssh/ui/widgets/button_box.dart';
import 'package:zestssh/utils/help_links.dart';

/// First-run "get connected" experience (Final doc F1).
///
/// Shown once, before the empty host grid, when the app has no saved
/// connections and onboarding hasn't been completed. Presents a one-line
/// product statement and the four ways to get servers in. Completing OR
/// skipping marks onboarding done so it never reappears.
///
/// Not signed in, it opens at a welcome first (before, a
/// new install said nothing of signing up or signing in). Since
/// 4.0 (on a computer
/// and on a phone): going on with no account is the main way, which keeps
/// everything on the device; Sign in is the second, and a new person makes an
/// account by signing in (no Create an account here); nothing says hosted
/// sync is free (it is part of Juiced). Only a new install comes here, so an
/// update never shows it.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  /// A test's word on whether the welcome is a phone's (a phone's or a
  /// tablet's words, and where a phone signs in later); null asks the system
  /// the app runs on.
  @visibleForTesting
  static bool? debugPhone;

  /// A test's stand-in for opening a page of the website in the browser.
  @visibleForTesting
  static Future<void> Function(Uri page)? debugOpenPage;

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

/// The website's page that says what Squeezed, Juiced and the Bundle are
/// (since 11 November 2026): What is Juiced? opens it, as the app's other
/// links to the site name it (its terms, its privacy page).
Uri get welcomePlansPage => Uri.parse(kZestPlansUrl);

enum _Step { welcome, overview, import, scan }

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  late _Step _step = ref.read(currentUserProvider) != null ? _Step.overview : _Step.welcome;

  /// A sign-in from the welcome is running.
  bool _signingIn = false;

  SshConfigScanResult? _detected;
  bool _detecting = true;

  @override
  void initState() {
    super.initState();
    _detect();
  }

  Future<void> _detect() async {
    final result = await const SshConfigSource().detect();
    if (!mounted) return;
    setState(() {
      _detected = result;
      _detecting = false;
    });
  }

  /// Mark onboarding complete and return to the (now populated, or empty)
  /// home. Optionally routes onward afterwards. Captures the router up front
  /// so it survives this screen being torn down by the redirect.
  Future<void> _finish({String? thenPush}) async {
    final router = GoRouter.of(context);
    await ref.read(settingsServiceProvider).setOnboardingComplete();
    router.go(Routes.home);
    if (thenPush != null) router.push(thenPush);
  }

  void _onImported(SshImportOutcome outcome) {
    final l10n = AppLocalizations.of(context)!;
    if (outcome.imported > 0) {
      showTopSnackBar(
        context,
        l10n.sshImportImportedCount(outcome.imported),
        isSuccess: true,
      );
      _finish();
    } else if (outcome.failedLimit > 0) {
      showTopSnackBar(context, l10n.sshImportSomeFailed(outcome.failedLimit),
          isError: true);
    }
  }

  void _onScanAdded(int added, int failedLimit) {
    final l10n = AppLocalizations.of(context)!;
    if (added > 0) {
      showTopSnackBar(
        context,
        l10n.sshImportImportedCount(added),
        isSuccess: true,
      );
      _finish();
    } else if (failedLimit > 0) {
      showTopSnackBar(context, l10n.sshImportSomeFailed(failedLimit),
          isError: true);
    }
  }

  /// Signs in from the welcome: in the browser on a computer without
  /// Firebase; on a device that signs in itself, with the way picked from the
  /// app's sheet (Apple, Google, email), where a new person makes their
  /// account as well. Signed in, it goes on to getting connected.
  Future<void> _signIn() async {
    if (_signingIn) return;
    final bool signedIn;
    if (!signsInOnDevice) {
      setState(() => _signingIn = true);
      signedIn = await signInInBrowser(context, ref);
    } else {
      final way = await showSignInWays(context);
      if (way == null || !mounted) return;
      setState(() => _signingIn = true);
      signedIn = await signInWith(context, ref, way);
    }
    if (!mounted) return;
    setState(() {
      _signingIn = false;
      if (signedIn) _step = _Step.overview;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_step == _Step.welcome) {
      return WindowBarOver(
        child: Scaffold(
          backgroundColor: AppColors.background,
          body: SafeArea(child: _buildWelcome()),
        ),
      );
    }
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width =
                constraints.maxWidth < 560 ? constraints.maxWidth : 560.0;
            return Center(
              child: SizedBox(
                // Explicit height keeps the import/scan steps' [Expanded]
                // lists bounded, while the overview step scrolls within it.
                width: width,
                height: constraints.maxHeight,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
                  child: switch (_step) {
                    // The welcome has a layout of its own (build).
                    _Step.welcome || _Step.overview => _buildOverview(),
                    _Step.import => _buildStep(
                        title:
                            AppLocalizations.of(context)!.firstRunImportTitle,
                        child: _detected == null
                            ? const SizedBox.shrink()
                            : SshConfigReview(
                                result: _detected!,
                                onImported: _onImported,
                              ),
                      ),
                    _Step.scan => _buildStep(
                        title: AppLocalizations.of(context)!.firstRunScanTitle,
                        child: LanScanView(onAdded: _onScanAdded),
                      ),
                  },
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildOverview() {
    final l10n = AppLocalizations.of(context)!;

    // Import tile copy reflects what detection found, before the user acts.
    final detected = _detected;
    final count = detected?.entries.length ?? 0;
    final String importSubtitle;
    final bool importEnabled;
    final bool importPrimary;
    if (_detecting) {
      importSubtitle = l10n.firstRunImportDescNone;
      importEnabled = false;
      importPrimary = false;
    } else if (detected == null) {
      importSubtitle = l10n.firstRunImportDescEmpty;
      importEnabled = false;
      importPrimary = false;
    } else if (count > 0) {
      importSubtitle = l10n.firstRunImportDescFound(count);
      importEnabled = true;
      importPrimary = true;
    } else {
      // Config present but nothing importable (e.g. only wildcards).
      importSubtitle = l10n.sshImportReviewNoneImportable;
      importEnabled = true;
      importPrimary = false;
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Image.asset(
              'assets/ZestSSH.png',
              width: 72,
              height: 72,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            l10n.firstRunTitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              color: AppColors.onBackground,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 8),
          // The single product statement - one sentence, reused in About.
          Text(
            l10n.productStatement,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14.5,
              color: AppColors.onSurfaceVariant,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 28),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              l10n.firstRunSectionTitle,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.0,
                color: AppColors.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 12),
          GetConnectedOptions(
            importSubtitle: importSubtitle,
            importEnabled: importEnabled,
            importPrimary: importPrimary,
            onImport: () => setState(() => _step = _Step.import),
            onScan: () => setState(() => _step = _Step.scan),
            onRestore: () => _finish(thenPush: Routes.profile),
            onAdd: () => _finish(thenPush: Routes.connectionEdit),
          ),
          const SizedBox(height: 20),
          Center(
            child: TextButton(
              onPressed: () => _finish(),
              child: Text(
                l10n.firstRunSkip,
                style: TextStyle(color: AppColors.onSurfaceVariant),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  /// The welcome: what the app is beside what to do on a wide window (the
  /// welcome on a computer), and on a phone what it is at the top and what
  /// to do at the foot, in reach of a thumb (the welcome on a phone).
  Widget _buildWelcome() {
    final phone = OnboardingScreen.debugPhone ?? isMobilePlatform;
    return LayoutBuilder(
      key: const ValueKey('welcome'),
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 820;
        final about = _WelcomeAbout(wide: wide, phone: phone);
        final actions = _WelcomeActions(
          wide: wide,
          phone: phone,
          signingIn: _signingIn,
          onStart: () => setState(() => _step = _Step.overview),
          onSignIn: _signIn,
        );
        if (wide) {
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 958, maxHeight: 518),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppColors.divider),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: about),
                        VerticalDivider(width: 1, thickness: 1, color: AppColors.divider),
                        SizedBox(width: 380, child: actions),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        }
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: _FillOrScroll(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 36, bottom: 12),
                      child: Center(child: about),
                    ),
                  ),
                  actions,
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildStep({required String title, required Widget child}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              onPressed: () => setState(() => _step = _Step.overview),
              icon: const Icon(LucideIcons.arrowLeft),
              tooltip: AppLocalizations.of(context)!.back,
              color: AppColors.onSurface,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: AppColors.onBackground,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(child: child),
      ],
    );
  }
}

/// [child], as tall as the room it is given where it fits (its [Expanded]
/// parts sharing what is left), and scrolling at its own height where it does
/// not (a short window, a large text size).
class _FillOrScroll extends StatelessWidget {
  const _FillOrScroll({required this.padding, required this.child});

  final EdgeInsets padding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // The padding inside what fills the room: around it, the padding at its
    // foot was below the room and taken for more to scroll to.
    return CustomScrollView(
      slivers: [
        SliverFillRemaining(hasScrollBody: false, child: Padding(padding: padding, child: child)),
      ],
    );
  }
}

/// The welcome's left (or upper) part: the app, what it is, that it is free
/// to use with no account, and three ticks about the app.
class _WelcomeAbout extends StatelessWidget {
  const _WelcomeAbout({required this.wide, required this.phone});

  final bool wide;

  /// A phone's or a tablet's words ("on this device").
  final bool phone;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final tick = TextStyle(fontSize: wide ? 14 : 14.5, height: 1.45, color: AppColors.onSurfaceVariant);
    Widget line(String text, {bool first = false}) => Padding(
          padding: EdgeInsets.only(top: first ? 0 : (wide ? 13 : 12)),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // A filled round tick in the text's colour, as the design draws
              // it (an orange tick had no meaning of its own).
              Container(
                width: 20,
                height: 20,
                margin: const EdgeInsets.only(top: 1),
                decoration: BoxDecoration(color: ZestTokens.surfaceChip, shape: BoxShape.circle),
                child: Icon(LucideIcons.check, size: 12, color: AppColors.onBackground),
              ),
              const SizedBox(width: 11),
              Expanded(child: Text(text, style: tick)),
            ],
          ),
        );
    final words = Column(
      crossAxisAlignment: wide ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(wide ? 14 : 18),
          child: Image.asset('assets/ZestSSH.png', width: wide ? 56 : 72, height: wide ? 56 : 72),
        ),
        SizedBox(height: wide ? 24 : 20),
        Text(
          l10n.welcomeTitle,
          textAlign: wide ? TextAlign.start : TextAlign.center,
          style: TextStyle(
            fontSize: wide ? 30 : 27,
            fontWeight: FontWeight.w700,
            height: 1.15,
            color: AppColors.onBackground,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 10),
        // What it is, and on a line of its own that it is free to use (a
        // width of its own made the pane's height be measured at another
        // width than it is drawn at, and its words ran over).
        Text(
          [l10n.welcomeLeadWhat, l10n.welcomeLeadFree].join('\n'),
          key: const ValueKey('welcome-lead'),
          textAlign: wide ? TextAlign.start : TextAlign.center,
          style: TextStyle(fontSize: 15, height: 1.5, color: AppColors.onSurfaceVariant),
        ),
        const SizedBox(height: 26),
        Column(
          key: const ValueKey('welcome-ticks'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            line(l10n.welcomeTickHosts, first: true),
            line(phone ? l10n.welcomeTickKeysDevice : l10n.welcomeTickKeysComputer),
            line(l10n.welcomeTickSync),
          ],
        ),
      ],
    );
    if (!wide) return words;
    // A warm light from the corner, the website's welcome.
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(-1, -1),
          radius: 1.3,
          colors: [AppColors.brandOrange.withValues(alpha: 0.10), Colors.transparent],
        ),
      ),
      child: _FillOrScroll(
        padding: const EdgeInsets.fromLTRB(46, 40, 40, 40),
        child: Align(alignment: AlignmentDirectional.centerStart, child: words),
      ),
    );
  }
}

/// The welcome's right (or lower) part: Start using ZestSSH, the way on with
/// no account, then Sign in, and at its foot what Juiced has to do with
/// sync. A computer, the Mac included, signs in in the browser; a phone and
/// a tablet with their own ways, from the app's sheet.
class _WelcomeActions extends StatelessWidget {
  const _WelcomeActions({
    required this.wide,
    required this.phone,
    required this.signingIn,
    required this.onStart,
    required this.onSignIn,
  });

  final bool wide;
  final bool phone;
  final bool signingIn;
  final VoidCallback onStart;
  final VoidCallback onSignIn;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final inApp = signsInOnDevice;
    // Apple's ways come first on Apple's devices (signInWaysHere).
    final apple = defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.macOS;
    final hint = TextStyle(fontSize: wide ? 12.5 : 13, height: 1.45, color: AppColors.onSurfaceVariant);
    final align = wide ? TextAlign.start : TextAlign.center;
    final radius = BorderRadius.circular(wide ? 12 : 14);
    final buttons = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ButtonBox(
          height: wide ? 52 : 54,
          child: FilledButton.icon(
            key: const ValueKey('welcome-start'),
            onPressed: onStart,
            iconAlignment: IconAlignment.end,
            icon: Icon(LucideIcons.arrowRight, size: wide ? 17 : 18),
            label: Text(l10n.welcomeStart, textAlign: TextAlign.center),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.brandOrange,
              foregroundColor: AppColors.onBrand(AppColors.brandOrange),
              shape: RoundedRectangleBorder(borderRadius: radius),
              textStyle: TextStyle(fontFamily: 'GeistSans', fontSize: wide ? 15.5 : 16, fontWeight: FontWeight.w600),
            ),
          ),
        ),
        const SizedBox(height: 9),
        Text(
          // A phone or a tablet whose screen is large has the computer's shell
          // (4.0), the account at the rail's foot, and no More tab.
          // A build with no account service says only where things stay.
          !zestHasCloud
              ? l10n.welcomeStaysHere
              : !phone
                  ? l10n.welcomeGuestComputer
                  : isLargeScreen(MediaQuery.sizeOf(context))
                      ? l10n.welcomeGuestTabletShell
                      : l10n.welcomeGuestPhone,
          key: const ValueKey('welcome-start-note'),
          textAlign: align,
          style: hint,
        ),
        // Sign in, under "or": only where the build signs anyone in.
        if (zestHasCloud) ...[
        Padding(
          padding: EdgeInsets.only(top: wide ? 22 : 16, bottom: wide ? 20 : 14),
          child: Row(
            children: [
              Expanded(child: Divider(height: 1, thickness: 1, color: ZestTokens.borderSubtle)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(l10n.profileOrDivider,
                    style: TextStyle(fontSize: wide ? 12 : 12.5, color: ZestTokens.textTertiary)),
              ),
              Expanded(child: Divider(height: 1, thickness: 1, color: ZestTokens.borderSubtle)),
            ],
          ),
        ),
        ButtonBox(
          height: wide ? 46 : 50,
          child: OutlinedButton(
            key: const ValueKey('welcome-sign-in'),
            onPressed: signingIn ? null : onSignIn,
            style: OutlinedButton.styleFrom(
              shape: RoundedRectangleBorder(borderRadius: radius),
              side: BorderSide(color: ZestTokens.borderStrong),
              backgroundColor: Colors.transparent,
              foregroundColor: AppColors.onBackground,
              textStyle: TextStyle(fontFamily: 'GeistSans', fontSize: wide ? 14.5 : 15, fontWeight: FontWeight.w600),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(child: Text(l10n.profileSignIn, textAlign: TextAlign.center)),
                // The browser opens: said by the icon as well as the line.
                if (!inApp) ...[
                  const SizedBox(width: 9),
                  Icon(LucideIcons.externalLink, size: 15, color: AppColors.onSurfaceVariant),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 9),
        if (signingIn && !inApp)
          Row(
            key: const ValueKey('welcome-browser-waiting'),
            children: [
              SizedBox(
                width: 15,
                height: 15,
                child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.brandOrange),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(l10n.signInBrowserWaiting, style: hint)),
            ],
          )
        else
          Text(
            inApp ? (apple ? l10n.welcomeSignInWaysApple : l10n.welcomeSignInWays) : l10n.welcomeBrowserNote,
            key: const ValueKey('welcome-sign-in-note'),
            textAlign: align,
            style: hint,
          ),
        ],
      ],
    );
    // (What Juiced is: only where the build has plans.)
    final Widget foot = zestHasPlans ? _JuicedLine(wide: wide) : const SizedBox.shrink();
    if (!wide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [buttons, if (zestHasPlans) const SizedBox(height: 14), foot],
      );
    }
    return _FillOrScroll(
      padding: const EdgeInsets.fromLTRB(32, 46, 32, 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: Center(child: buttons)),
          const SizedBox(height: 20),
          foot,
        ],
      ),
    );
  }
}

/// The welcome's quiet foot: hosted sync on ZestSSH Cloud is part of Juiced,
/// and What is Juiced?, which opens the website's page on the plans.
class _JuicedLine extends StatelessWidget {
  const _JuicedLine({required this.wide});

  final bool wide;

  Future<void> _open() async {
    final open = OnboardingScreen.debugOpenPage;
    if (open != null) return open(welcomePlansPage);
    await launchUrl(welcomePlansPage, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final words = TextStyle(fontSize: 12.5, height: 1.45, color: AppColors.onSurfaceVariant);
    // A link, as a screen reader says it, not a button: it opens a page.
    final link = MergeSemantics(
      child: Semantics(
        link: true,
        child: InkWell(
          key: const ValueKey('welcome-what-is-juiced'),
          onTap: _open,
          borderRadius: BorderRadius.circular(6),
          child: ConstrainedBox(
            // A finger's target on a phone; a link's on a computer.
            constraints: BoxConstraints(minHeight: wide ? 26 : 48),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: wide ? 0 : 10),
              child: Align(
                widthFactor: 1,
                heightFactor: 1,
                child: Text(
                  l10n.welcomeWhatIsJuiced,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.45,
                    color: AppColors.onSurface,
                    decoration: TextDecoration.underline,
                    decorationColor: ZestTokens.textTertiary,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final line = Text(l10n.welcomeJuicedLine, key: const ValueKey('welcome-juiced'), textAlign: wide ? TextAlign.start : TextAlign.center, style: words);
    return Container(
      padding: EdgeInsets.only(top: wide ? 16 : 12),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: ZestTokens.borderSubtle))),
      child: wide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(LucideIcons.cloud, size: 15, color: AppColors.onSurfaceVariant),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [line, link],
                  ),
                ),
              ],
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [line, link],
            ),
    );
  }
}
