import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// Both views, and the settings: one provider among them (two of the same
// name made this file ambiguous before).
import 'package:zestssh/features/screens/desktop/screen_pane.dart';
import 'package:zestssh/features/screens/phone/phone_screen_view.dart';
import 'package:zestssh/features/screens/screen_settings.dart';

/// "Show for this session" in recording mode (4.0): the desktop tab
/// and the phone screen keep the sessions shown in one set, so a session
/// shown in one is shown in the other.
void main() {
  test('one set of shown sessions for the desktop tab and the phone screen', () {
    expect(ScreenPane, isNotNull);
    expect(PhoneScreenView, isNotNull);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(screenShownWhileRecordingProvider), isEmpty);
    container.read(screenShownWhileRecordingProvider.notifier).state = {'s1'};
    bool covered(String id) => screenCoveredWhileRecording(
          recording: true,
          behaviour: ScreenRecordingBehaviour.cover,
          shown: container.read(screenShownWhileRecordingProvider).contains(id),
        );
    expect(covered('s1'), isFalse);
    expect(covered('s2'), isTrue, reason: 'another session is covered');
  });
}
