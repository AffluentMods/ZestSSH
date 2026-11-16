import 'package:flutter_test/flutter_test.dart';
import 'package:zest_native/zest_native.dart';

/// The app's native library (3.4): the Rust crate in packages/zest_native is built by its build
/// hook as the app's tests are, and loads in them as it does in the app.
void main() {
  test('the Rust library is built with the app, loads, and says its name and version', () {
    expect(zestNativeVersion(), 'zest_native 0.1.0');
  });
}
