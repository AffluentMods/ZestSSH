import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/window_service.dart';
import 'package:zestssh/ui/widgets/window_bar.dart';

/// A computer's window has no frame of the system's, so a screen shown without the
/// shell had no way to move the window, minimize it or close it, and a locked app
/// could only be force closed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));
  final calls = <String>[];
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(const MethodChannel('window_manager'), (call) async {
      calls.add(call.method);
      return call.method == 'isMaximized' ? false : null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(const MethodChannel('window_manager'), null));

  Future<void> pump(WidgetTester tester, {bool? shown, VoidCallback? onTapBehind}) => tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: WindowBarOver(
          shown: shown,
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: TextButton(onPressed: onTapBehind, child: const Text('behind')),
            ),
          ),
        ),
      ));

  testWidgets('over a screen without the shell: the controls, and they do what they say', (tester) async {
    await pump(tester, shown: true);
    await tester.pump();
    expect(find.byTooltip(en.pillMinimize), findsOneWidget);
    expect(find.byTooltip(en.pillMaximize), findsOneWidget);
    expect(find.byTooltip(en.close), findsOneWidget);

    await tester.tap(find.byTooltip(en.pillMinimize));
    await tester.tap(find.byTooltip(en.close));
    await tester.pump();
    expect(calls, containsAll(['minimize', 'close']));
    // At the window's corner, as the pill bar's are.
    final size = tester.getSize(find.byType(Scaffold));
    expect(tester.getTopRight(find.byType(WindowControls)).dx, size.width);
    expect(tester.getTopRight(find.byType(WindowControls)).dy, 0);
  });

  testWidgets('what lies under the moving part still takes its taps', (tester) async {
    var tapped = 0;
    await pump(tester, shown: true, onTapBehind: () => tapped++);
    await tester.tap(find.text('behind'));
    await tester.pump();
    expect(tapped, 1);
  });

  testWidgets('with no window to work (a phone, the system\'s frame, a window that failed): the screen alone',
      (tester) async {
    await pump(tester);
    await tester.pump();
    expect(find.byType(WindowControls), findsNothing);
    expect(calls, isEmpty);
  });

  test('every screen a computer shows without the shell has it', () {
    for (final path in [
      'lib/ui/screens/security/security_lock_screen.dart',
      'lib/features/onboarding/onboarding_screen.dart',
      'lib/ui/screens/error/startup_error_screen.dart',
      'lib/ui/screens/error/database_error_screen.dart',
      'lib/ui/screens/error/migration_error_screen.dart',
    ]) {
      expect(File(path).readAsStringSync(), contains('WindowBarOver('), reason: path);
    }
  });

  group('the window\'s close', () {
    test('reaches the shell while it is there, and what stays once it has gone', () {
      messenger.setMockMethodCallHandler(const MethodChannel('window_manager'), (call) async => null);
      final window = WindowService.forTesting();
      final said = <String>[];
      void shell() => said.add('shell');
      void app() => said.add('app');

      window.setOnCloseWithoutShell(app);
      window.onWindowClose();
      expect(said, ['app'], reason: 'started locked: no shell yet');

      window.setOnCloseRequested(shell);
      window.onWindowClose();
      expect(said, ['app', 'shell']);

      // The app locked: the shell has gone, and a close sent to it would do nothing.
      window.clearOnCloseRequested(shell);
      window.onWindowClose();
      expect(said, ['app', 'shell', 'app']);
    });

    test('another screen\'s going does not take away what the screen on show set', () {
      messenger.setMockMethodCallHandler(const MethodChannel('window_manager'), (call) async => null);
      final window = WindowService.forTesting();
      final said = <String>[];
      void first() => said.add('first');
      void second() => said.add('second');
      window.setOnCloseRequested(first);
      window.setOnCloseRequested(second);
      window.clearOnCloseRequested(first);
      window.onWindowClose();
      expect(said, ['second']);
    });
  });
}
