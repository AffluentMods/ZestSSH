import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/ui/screens/desktop/widgets/desktop_status_bar.dart';

/// A computer's status bar ticked once a second for as long as the window
/// lived, with no session open and while minimised: one wake and one frame a
/// second, so the process never went idle (found in a review). With
/// nothing that counts on it, it does not tick, and five seconds ask for no
/// frame.
void main() {
  testWidgets('no session, no vault open: the bar asks for no frame', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1400, 200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      // Its own half-minute clock is not the bar's.
      syncHealthClockProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: Scaffold(body: Align(alignment: Alignment.bottomCenter, child: DesktopStatusBar())),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 500));
    final state = tester.state<ConsumerState<DesktopStatusBar>>(find.byType(DesktopStatusBar)) as dynamic;
    expect(state.ticking, isFalse);
    var frames = 0;
    for (var i = 0; i < 5; i++) {
      // A second goes by with no frame drawn: did anything ask for one?
      await tester.binding.delayed(const Duration(seconds: 1));
      if (tester.binding.hasScheduledFrame) frames++;
      await tester.pump();
    }
    expect(frames, 0, reason: 'a frame a second with nothing to count');
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    await tester.pump(const Duration(minutes: 1));
  });
}
