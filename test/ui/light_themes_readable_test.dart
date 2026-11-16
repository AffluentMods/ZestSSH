import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/features/hosts/widgets/host_grid_area.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/monitoring_providers.dart';
import 'package:zestssh/services/prometheus_secure_settings.dart';
import 'package:zestssh/services/security_lock_service.dart';
import 'package:zestssh/services/vault_slot_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/monitoring/prometheus_config_sheet.dart';
import 'package:zestssh/ui/screens/security/security_lock_screen.dart';
import 'package:zestssh/ui/screens/sftp/sftp_browser_screen.dart';
import 'package:zestssh/ui/screens/terminal/widgets/terminal_soft_keyboard.dart';
import 'package:zestssh/ui/widgets/button_spinner.dart';
import 'package:zestssh/ui/widgets/paste_question.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

import '../helpers/painted_contrast.dart';
import '../visual/shots_util.dart';

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
  Future<void> setLockMethod(SecurityLockMethod method) async {}
  @override
  Future<SecurityLockMethod> getLockMethod() async => SecurityLockMethod.pin;
  @override
  Future<bool> isBiometricAvailable() async => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// No vault on this device.
class _Vault implements VaultSlotService {
  @override
  Future<bool> isEnabled() async => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// What the app draws reads on every theme, the light ones too (3.0).
/// A text, an icon or a spinner in a fixed white on a surface
/// that follows the theme is white on near-white once a light theme is
/// chosen: on Daylight, One Light and IntelliJ Light the lines a paste
/// question shows before they run, every key above a phone's keyboard, the
/// PIN typed on the lock screen, a dialog's button turned off, the Prometheus
/// sheet's sentences, the place of a host whose card could not be drawn, and
/// the spinners of sixteen buttons while they work were so. And the accent as
/// a label (a text button's, a dialog's answer that is not filled) was the
/// accent as it is, which on Daylight is an orange of 2.3:1. Each surface here
/// is drawn in each light theme and in the default dark one, and every text,
/// icon and spinner on it must read at 2:1 or better on what is painted
/// behind it (the dimmest step the themes themselves allow; white on white is
/// about 1:1); labels in the accent at 4.5:1, as text; a spinner at 3:1.
void main() {
  const themes = ['default_light', 'one_light', 'intellij_light', 'default_dark'];
  final en = lookupAppLocalizations(const Locale('en'));
  const phone = Size(420, 860);
  const computer = Size(1200, 900);

  tearDown(() => AppColors.applyTheme(BuiltInThemes.getById('default_dark').colorScheme));

  /// [child] in the theme [id], on a phone's screen unless [size] says
  /// otherwise; settled unless it shows a spinner, which never settles.
  Future<void> show(WidgetTester tester, String id, Widget child,
      {Size size = phone, List<Override> overrides = const [], Map<String, Object> prefs = const {}, bool settle = true}) async {
    await tester.runAsync(loadShotFonts);
    final theme = BuiltInThemes.getById(id);
    AppColors.applyTheme(theme.colorScheme);
    SharedPreferences.setMockInitialValues(prefs);
    FlutterSecureStorage.setMockInitialValues({});
    final p = await SharedPreferences.getInstance();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(p), ...overrides],
      child: MaterialApp(
        theme: theme.toThemeData(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: child),
      ),
    ));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Color page(WidgetTester tester) => Theme.of(tester.element(find.byType(Scaffold).first)).scaffoldBackgroundColor;

  List<PaintedText> shown(WidgetTester tester) => paintedTexts(tester, fallbackGround: page(tester));

  void allRead(WidgetTester tester) => expect(hardToRead(tester, fallbackGround: page(tester)), isEmpty);

  Widget opener(void Function(BuildContext context) open) =>
      Builder(builder: (context) => Center(child: TextButton(onPressed: () => open(context), child: const Text('open'))));

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  for (final id in themes) {
    testWidgets('$id: the paste question, the lines it would paste first of all', (tester) async {
      await show(tester, id, opener((context) => showPasteQuestion(context, 'sudo systemctl restart nginx\nls -la /etc', runs: true)));
      await open(tester);
      expect(shown(tester).where((t) => t.text.startsWith('sudo systemctl')), isNotEmpty, reason: 'the lines are shown');
      allRead(tester);
      // The question's own buttons: Cancel is a text button.
      final cancel = shown(tester).firstWhere((t) => t.text == en.cancel);
      expect(cancel.ratio, greaterThanOrEqualTo(4.5), reason: "a text button's label reads as text: $cancel");
    });

    testWidgets("$id: a phone's keys above its keyboard, and a key held on", (tester) async {
      await show(tester, id, Align(alignment: Alignment.bottomCenter, child: TerminalSoftKeyboard(onKey: (_) {})));
      expect(find.text('ESC'), findsOneWidget);
      allRead(tester);
      await tester.tap(find.text('CTRL'));
      await tester.pumpAndSettle();
      final ctrl = shown(tester).firstWhere((t) => t.text == 'CTRL');
      expect(ctrl.ratio, greaterThanOrEqualTo(4.5), reason: 'held on, on the accent: $ctrl');
      allRead(tester);
    });

    testWidgets('$id: the lock screen, its placeholder and the PIN as it is typed', (tester) async {
      await show(tester, id, const SecurityLockScreen(),
          prefs: {'security_lock_enabled': true},
          overrides: [
            securityLockServiceProvider.overrideWithValue(_Lock()),
            vaultSlotServiceProvider.overrideWithValue(_Vault()),
          ]);
      allRead(tester);
      await tester.enterText(find.byType(TextField).first, '12');
      await tester.pump();
      final typed = shown(tester).where((t) => t.text == 'typed (hidden)').toList();
      expect(typed, hasLength(1), reason: 'what is typed is measured');
      expect(typed.single.ratio, greaterThanOrEqualTo(4.5), reason: '${typed.single}');
      allRead(tester);
    });

    testWidgets("$id: an app's dialog with its button turned off", (tester) async {
      await show(
          tester,
          id,
          opener((context) => ZestDialogShell.showModal<void>(context,
              size: ZestModalSize.standard,
              tone: ZestDialogTone.info,
              title: 'Save the host',
              body: const Text('A sentence.'),
              primaryAction: (label: 'Save', onPressed: null, icon: LucideIcons.save),
              secondaryAction: (label: en.cancel, onPressed: () {}))),
          size: computer);
      await open(tester);
      expect(shown(tester).where((t) => t.text == 'Save'), isNotEmpty);
      allRead(tester);
    });

    testWidgets("$id: an app's question whose answer is not filled", (tester) async {
      await show(
          tester,
          id,
          opener((context) => ZestConfirmDialog.show(context,
              tone: ZestDialogTone.info,
              title: 'A question',
              body: 'A sentence.',
              confirmLabel: 'Import',
              cancelLabel: 'Paste')),
          size: computer);
      await open(tester);
      final answer = shown(tester).firstWhere((t) => t.text == 'Import');
      expect(answer.ratio, greaterThanOrEqualTo(4.5), reason: 'the accent as a label: $answer');
      allRead(tester);
    });

    testWidgets("$id: a Prometheus connection's sheet, its TLS settings open", (tester) async {
      await show(tester, id, const PrometheusConfigSheet(), overrides: [
        prometheusSecureSettingsProvider.overrideWithValue(PrometheusSecureSettings(const FlutterSecureStorage())),
      ]);
      await tester.ensureVisible(find.text(en.monitorPrometheusTlsSettings));
      await tester.tap(find.text(en.monitorPrometheusTlsSettings));
      await tester.pumpAndSettle();
      expect(shown(tester).where((t) => t.text == en.monitorPrometheusCaCertDesc), isNotEmpty);
      allRead(tester);
    });

    testWidgets('$id: the place of a host whose card could not be drawn', (tester) async {
      await show(tester, id, const Center(child: HostTileNotShown(width: 300)));
      expect(shown(tester).where((t) => t.text == en.hostNotShown), isNotEmpty);
      allRead(tester);
    });

    testWidgets('$id: a spinner in a button that is turned off while it works, and in one that is not', (tester) async {
      Widget button({required bool on}) => FilledButton(
            onPressed: on ? () {} : null,
            style: FilledButton.styleFrom(backgroundColor: AppColors.brandOrange),
            child: const SizedBox(width: 16, height: 16, child: ButtonSpinner()),
          );
      // Built once the theme is set: the brand orange follows each theme's own accent.
      await show(
          tester,
          id,
          Builder(
              builder: (_) =>
                  Center(child: Column(mainAxisSize: MainAxisSize.min, children: [button(on: false), button(on: true)]))),
          settle: false);
      final spinners = shown(tester).where((t) => t.text == 'spinner').toList();
      expect(spinners, hasLength(2));
      for (final s in spinners) {
        expect(s.ratio, greaterThanOrEqualTo(3.0), reason: '$s');
      }
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets("$id: a text button's and an outlined button's labels, the accent as text", (tester) async {
      await show(
          tester,
          id,
          Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextButton(onPressed: () {}, child: const Text('Text label')),
              OutlinedButton(onPressed: () {}, child: const Text('Outlined label')),
            ]),
          ));
      for (final label in ['Text label', 'Outlined label']) {
        final t = shown(tester).firstWhere((t) => t.text == label);
        expect(t.ratio, greaterThanOrEqualTo(4.5), reason: '$t');
      }
    });

    testWidgets("$id: a phone's SFTP upload button while a transfer runs", (tester) async {
      await show(tester, id, const SizedBox());
      final dimmed = sftpUploadButtonColors(transferring: true, page: page(tester));
      final pair = PaintedText(text: 'upload', ink: dimmed.ink, ground: dimmed.fill, groundBy: 'the button');
      expect(pair.ratio, greaterThanOrEqualTo(3.0), reason: '$pair');
    });
  }

  test('no spinner of the app is drawn in a fixed white', () {
    final found = <String>[];
    const head = 'CircularProgressIndicator(';
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      final path = file.path.replaceAll('\\', '/');
      if (!path.endsWith('.dart') || path.contains('/generated/')) continue;
      final text = file.readAsStringSync();
      for (var i = text.indexOf(head); i >= 0; i = text.indexOf(head, i + head.length)) {
        var k = i + head.length;
        for (var depth = 1; depth > 0 && k < text.length; k++) {
          if (text[k] == '(') depth++;
          if (text[k] == ')') depth--;
        }
        if (text.substring(i, k).contains('Colors.white')) found.add('$path:${'\n'.allMatches(text.substring(0, i)).length + 1}');
      }
    }
    expect(found, isEmpty, reason: 'in a button, a ButtonSpinner takes the button\'s own ink');
  });

  test('the check itself: white on a light ground is hard to read, and the ink of a fill is not', () {
    final white = PaintedText(text: 'a', ink: Colors.white70, ground: const Color(0xFFF0F2F5), groundBy: 'x');
    expect(white.ratio, lessThan(2.0));
    const orange = Color(0xFFFF7A1A);
    final ink = PaintedText(text: 'b', ink: ZestColors.onFill(orange), ground: orange, groundBy: 'x');
    expect(ink.ratio, greaterThanOrEqualTo(4.5));
  });
}
