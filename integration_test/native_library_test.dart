// The app's Rust library on a real device, with no server: the build hook's
// library for the device's ABI is in the APK, loads, and says its name and
// version (test/native/zest_native_test.dart checks the same on the computer
// that runs the suite). Written for Firebase Test Lab (tool/test_lab), where
// the devices reach none of the WSL test servers; runs anywhere:
//
//   flutter test integration_test/native_library_test.dart -d <device>
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zest_native/zest_native.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the Rust library loads on this device and says its name and version', (tester) async {
    debugPrint('device: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
    expect(zestNativeVersion(), 'zest_native 0.1.0');
  });
}
