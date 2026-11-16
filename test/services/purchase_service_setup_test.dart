import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:zestssh/services/purchase_service.dart';

/// A phone build whose purchases cannot be set up still starts: a debug
/// build with no RevenueCat key stood at "ZestSSH could not start" (seen in
/// an emulator), as Purchases.configure threw
/// and the start let it through.
void main() {
  test('a build with no key does not ask RevenueCat and goes on', () async {
    var asked = 0;
    final ready = await PurchaseService.configureWith('', configure: (_) async => asked++);
    expect(ready, isFalse);
    expect(asked, 0);
  });

  test('a setup RevenueCat refuses is caught, and the app goes on', () async {
    final ready = await PurchaseService.configureWith(
      'goog_demo',
      configure: (_) async =>
          throw PlatformException(code: 'error', message: 'API key must be set. Get this from the RevenueCat web app'),
    );
    expect(ready, isFalse);
  });

  test('a key RevenueCat takes is set up with that key', () async {
    PurchasesConfiguration? given;
    final ready = await PurchaseService.configureWith('goog_demo', configure: (c) async => given = c);
    expect(ready, isTrue);
    expect(given?.apiKey, 'goog_demo');
  });
}
