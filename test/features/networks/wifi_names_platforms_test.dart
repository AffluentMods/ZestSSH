import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/networks/engine/network_state.dart';

/// Wi-Fi name rules are offered only where the system gives ZestSSH the
/// Wi-Fi name: a Mac gives it only to an app with
/// Location Services, which ZestSSH does not declare, so the rule never
/// matched there.
void main() {
  test('Windows and Linux read it; macOS, Android and iOS do not', () {
    expect(wifiNamesReadOn('windows'), isTrue);
    expect(wifiNamesReadOn('linux'), isTrue);
    expect(wifiNamesReadOn('macos'), isFalse);
    expect(wifiNamesReadOn('android'), isFalse);
    expect(wifiNamesReadOn('ios'), isFalse);
  });
}
