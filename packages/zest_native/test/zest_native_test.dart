import 'package:test/test.dart';
import 'package:zest_native/zest_native.dart';

void main() {
  test('the Rust library is built, loaded and answers with its name and version', () {
    expect(zestNativeVersion(), 'zest_native 0.1.0');
  });
}
