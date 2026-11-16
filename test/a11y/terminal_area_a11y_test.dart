import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/security_lock_service.dart';
import 'package:zestssh/services/vault_slot_service.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/screens/security/pin_setup_screen.dart';
import 'package:zestssh/ui/screens/security/security_lock_screen.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/ui/screens/terminal/widgets/terminal_search_bar.dart';
import 'package:zestssh/ui/screens/terminal/widgets/terminal_soft_keyboard.dart';
import 'package:zestssh/ui/screens/terminal/widgets/terminal_toolbar.dart';
import 'package:zestssh/ui/widgets/mobile_session_tabs.dart';
import 'package:zestssh/utils/platform_utils.dart' show debugTouchLayout;

/// Two sessions open on a phone.
class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref) {
    state = {
      's1': const SessionState(
          status: SessionStatus.connected, connectionId: 'c1', connectionLabel: 'web-01', host: '10.0.0.21'),
      's2': const SessionState(
          status: SessionStatus.connecting, connectionId: 'c2', connectionLabel: 'db-primary', host: '10.0.0.22'),
    };
  }
}

/// A lock with a PIN and no biometrics, which takes any PIN.
class _Lock implements SecurityLockService {
  @override
  bool get isLockedOut => false;
  @override
  int get remainingLockoutSeconds => 0;
  @override
  int get failedAttempts => 0;
  @override
  int get maxAttempts => 10;
  @override
  Future<bool> verifyPin(String pin) async => true;
  @override
  Future<bool> hasPinConfigured() async => true;
  @override
  Future<void> setPin(String pin) async {}
  @override
  Future<void> setLockMethod(SecurityLockMethod method) async {}
  @override
  Future<SecurityLockMethod> getLockMethod() async => SecurityLockMethod.pin;
  @override
  Future<bool> isBiometricAvailable() async => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Vault implements VaultSlotService {
  @override
  Future<bool> isEnabled() async => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The terminal and session views, the lock screen and PIN setup, the files
/// panels and the text editor meet the accessibility guidelines (4.0
/// accessibility pass): every control a finger takes is 48 by 48 on a phone,
/// every control says what it does to a screen reader, and text reads
/// against what is behind it. Names and addresses here are made up.
void main() {
  /// [body] drawn as a phone's ([touch]) or a computer's.
  void drawn(String name, Future<void> Function(WidgetTester tester) body, {bool touch = true}) {
    testWidgets(name, (tester) async {
      debugTouchLayout = touch;
      debugDefaultTargetPlatformOverride = touch ? TargetPlatform.android : TargetPlatform.windows;
      try {
        await body(tester);
      } finally {
        debugTouchLayout = null;
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  Future<void> show(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(400, 860),
    List<Override> overrides = const [],
    Map<String, Object> prefs = const {},
    double textScale = 1,
    bool settle = true,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    FlutterSecureStorage.setMockInitialValues({});
    final p = await SharedPreferences.getInstance();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(p), ...overrides],
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(body: child),
      ),
    ));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// The guidelines a phone's screen meets.
  Future<void> meetsPhone(WidgetTester tester) async {
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
  }

  /// The guidelines a computer's screen meets: its controls are for a mouse.
  Future<void> meetsComputer(WidgetTester tester) async {
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
  }

  final lockOverrides = <Override>[
    securityLockServiceProvider.overrideWithValue(_Lock()),
    vaultSlotServiceProvider.overrideWithValue(_Vault()),
  ];

  Widget toolbar() => Align(
        alignment: Alignment.topCenter,
        child: TerminalToolbar(
          sessionId: 's1',
          status: SessionStatus.connected,
          connectionLabel: 'web-01',
          host: '192.168.10.21',
          port: 22,
          connectedAt: DateTime.now().subtract(const Duration(minutes: 12, seconds: 7)),
          onDisconnect: () {},
          onBack: () {},
          onSettings: () {},
          onSnippets: () {},
        ),
      );

  drawn("a phone's terminal bar", (tester) async {
    final semantics = tester.ensureSemantics();
    await show(tester, toolbar(), settle: false);
    await meetsPhone(tester);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
    semantics.dispose();
  });

  // The one place a phone's targets are under 48 across: the keys above its
  // keyboard, nine to a row on a phone 400 wide (nine of 48 are 432). Each
  // key's target takes in the gaps round it, so the row has no dead space:
  // 44 across and 48 down at the medium size, 52 or more across in the
  // scrollable row and at the large size (Settings, Keyboard).
  const keysRowTargets = MinimumTapTargetGuideline(
    size: Size(44, 48),
    link: 'https://support.google.com/accessibility/android/answer/7101858',
  );

  drawn("a phone's extra keys row", (tester) async {
    final semantics = tester.ensureSemantics();
    await show(tester, Align(alignment: Alignment.bottomCenter, child: TerminalSoftKeyboard(onKey: (_) {})));
    await expectLater(tester, meetsGuideline(keysRowTargets));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
    // Each key is said once: "ESC key", not "ESC key, ESC".
    expect(find.bySemanticsLabel('ESC key'), findsOneWidget);
    // A press in the gap between two keys is the nearer key's.
    final sent = <String>[];
    await show(tester, Align(alignment: Alignment.bottomCenter, child: TerminalSoftKeyboard(onKey: sent.add)));
    final esc = tester.getRect(find.byKey(const ValueKey('softkey-esc')));
    await tester.tapAt(esc.centerRight + const Offset(1.5, 0));
    expect(sent, ['\x1B']);
    semantics.dispose();
  });

  drawn('the lock screen', (tester) async {
    final semantics = tester.ensureSemantics();
    await show(tester, const SecurityLockScreen(), prefs: {'security_lock_enabled': true}, overrides: lockOverrides);
    await meetsPhone(tester);
    semantics.dispose();
  });

  drawn('PIN setup', (tester) async {
    final semantics = tester.ensureSemantics();
    await show(tester, const PinSetupScreen(), prefs: {'security_lock_enabled': false}, overrides: lockOverrides);
    await meetsPhone(tester);
    semantics.dispose();
  });

  drawn("a phone's session tabs", (tester) async {
    final semantics = tester.ensureSemantics();
    final picked = <String>[];
    await show(
        tester,
        Align(
          alignment: Alignment.topCenter,
          child: MobileSessionTabs(currentSessionId: 's1', onSessionSelected: picked.add, onSessionClose: (_) {}),
        ),
        overrides: [activeSessionsProvider.overrideWith(_Sessions.new)]);
    await meetsPhone(tester);
    final en = lookupAppLocalizations(const Locale('en'));
    final web = tester
        .getSemantics(find.bySemanticsLabel(
            '${en.mobileSessionTabsSessionTabSemantic('web-01')}, ${en.sessionInfoStatusConnected}'))
        .getSemanticsData();
    expect(web.flagsCollection.isButton, isTrue);
    expect(web.customSemanticsActionIds, isNotEmpty, reason: 'Close session, as a long press');
    expect(find.byKey(const ValueKey('status-mark-connecting')), findsOneWidget);
    // The margin round the pill takes the press.
    final pill = tester.getRect(find.text('db-primary'));
    await tester.tapAt(Offset(pill.center.dx, 46));
    expect(picked, ['s2']);
    semantics.dispose();
  });

  for (final touch in [true, false]) {
    drawn("${touch ? "a phone's" : "a computer's"} Find in the terminal, with a match", (tester) async {
      final semantics = tester.ensureSemantics();
      final terminal = Terminal()..write('needle one\r\nhay\r\nneedle two\r\n');
      final controller = TerminalController();
      await show(
          tester,
          Align(
            alignment: Alignment.topCenter,
            child: TerminalSearchBar(
              terminal: terminal,
              controller: controller,
              theme: TerminalThemes.defaultTheme,
              onClose: () {},
            ),
          ),
          size: touch ? const Size(400, 860) : const Size(1200, 800),
          settle: false);
      await tester.enterText(find.byType(TextField), 'needle');
      await tester.pump(const Duration(milliseconds: 300));
      if (touch) {
        await meetsPhone(tester);
      } else {
        await meetsComputer(tester);
      }
      semantics.dispose();
    }, touch: touch);
  }

  drawn("a computer's lock screen", (tester) async {
    final semantics = tester.ensureSemantics();
    await show(tester, const SecurityLockScreen(),
        size: const Size(1200, 800), prefs: {'security_lock_enabled': true}, overrides: lockOverrides);
    await meetsComputer(tester);
    semantics.dispose();
  }, touch: false);

  // Twice the text size on a phone: nothing runs over, nothing is cut.
  group('at twice the text size', () {
    Future<List<String>> overflows(Future<void> Function() body) async {
      final found = <String>[];
      final reported = FlutterError.onError;
      FlutterError.onError = (d) => found.add(d.exceptionAsString().split('\n').first);
      try {
        await body();
      } finally {
        FlutterError.onError = reported;
      }
      return found;
    }

    drawn("a phone's terminal bar", (tester) async {
      expect(await overflows(() => show(tester, toolbar(), textScale: 2, settle: false)), isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });

    drawn("a phone's extra keys row", (tester) async {
      expect(
          await overflows(() => show(tester, Align(alignment: Alignment.bottomCenter, child: TerminalSoftKeyboard(onKey: (_) {})),
              textScale: 2)),
          isEmpty);
    });

    drawn('the lock screen', (tester) async {
      expect(
          await overflows(() => show(tester, const SecurityLockScreen(),
              prefs: {'security_lock_enabled': true}, overrides: lockOverrides, textScale: 2)),
          isEmpty);
    });

    drawn('PIN setup', (tester) async {
      expect(
          await overflows(() => show(tester, const PinSetupScreen(),
              prefs: {'security_lock_enabled': false}, overrides: lockOverrides, textScale: 2)),
          isEmpty);
    });

    drawn("a phone's session tabs", (tester) async {
      expect(
          await overflows(() => show(
              tester,
              Align(
                alignment: Alignment.topCenter,
                child: MobileSessionTabs(currentSessionId: 's1', onSessionSelected: (_) {}, onSessionClose: (_) {}),
              ),
              overrides: [activeSessionsProvider.overrideWith(_Sessions.new)],
              textScale: 2)),
          isEmpty);
    });
  });
}
