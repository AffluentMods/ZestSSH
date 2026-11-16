import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/purchase_service.dart';

/// The link a computer's Upgrade opens in the browser (3.0, found 16 October
/// 2026 while comparing the five versions). It carried the id of the account
/// signed in to the app, or, where a computer's sign-in had kept no id, the
/// stand-in it keeps in its place, as if it were one; the website reads
/// neither (the purchase goes to the account signed in there, which the
/// server reads from that sign-in), so the id only sat in the browser's
/// history and the website's logs. Now the link names no account.
void main() {
  test('the link to the checkout names the tier, the way back and the platform, and no account', () {
    for (final tier in ['pro', 'cloud_sync', 'everything']) {
      final link = PurchaseService.buildWebUpgradeUrl(tier: tier);
      expect(link.toString(), startsWith('https://zestssh.com/upgrade?'), reason: tier);
      expect(link.queryParameters, {
        'tier': tier,
        'return': 'zestssh://upgrade-complete',
        'platform': Platform.operatingSystem,
      }, reason: tier);
    }
    expect(PurchaseService.buildWebUpgradeUrl().queryParameters['tier'], 'pro');
  });
}
