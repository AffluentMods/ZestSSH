import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/pinned_http_client.dart';

/// A certificate that fails the system's checks is refused, whatever its hash
/// (found in a security review): a version before
/// 1.7 kept the hash of one such certificate on first contact, a proxy's or
/// an attacker's, and later builds let it through where its hash was kept.
class _Cert implements X509Certificate {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the hashes an old build kept are deleted as the app starts, and a certificate that failed the checks is '
      'refused, for ZestSSH Cloud as for any host', () async {
    final kept = sha256.convert(utf8.encode('the certificate an old build met')).toString();
    FlutterSecureStorage.setMockInitialValues({'pinned_cert_hashes': jsonEncode([kept]), 'device_id': 'demo'});
    await PinnedHttpClient.init();
    final storage = await const FlutterSecureStorage().readAll();
    expect(storage.containsKey('pinned_cert_hashes'), isFalse);
    expect(storage['device_id'], 'demo', reason: 'nothing else is touched');

    expect(PinnedHttpClient.refuseBadCertificate(_Cert(), 'api.zestssh.com', 443), isFalse);
    expect(PinnedHttpClient.refuseBadCertificate(_Cert(), 'sync.example.com', 443), isFalse);
    // Every client the app makes for ZestSSH Cloud is given that check.
    final source = File('lib/services/pinned_http_client.dart').readAsStringSync();
    expect(source, contains('..badCertificateCallback = refuseBadCertificate;'));
    expect(source, contains('IOClient(newHttpClient())'));
  });
}
