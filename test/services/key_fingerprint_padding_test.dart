// A key's fingerprint, as ssh-keygen -l writes it (found
// while adding a host shared as a file): one imported into the app (a file,
// a paste, a shared host) was kept with base64's padding, "SHA256:...=",
// where ssh-keygen and a key made in the app write none; so it matched
// neither by eye, and the same key imported and made was not seen as one.

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/models/enums.dart' show KeyType;
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/services/key_generation_service.dart';
import 'package:zestssh/services/key_import_service.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_controller.dart';

Identity _key(String id, String? fingerprint) => Identity(
      id: id,
      label: 'key $id',
      username: 'deploy',
      authMethod: 'publicKey',
      publicKeyFingerprint: fingerprint,
      usesAgent: false,
      colorIndex: 0,
      isDefault: false,
      allowUnattended: false,
      passwordAfterKey: false,
      createdAt: DateTime(2026, 10, 16),
      updatedAt: DateTime(2026, 10, 16),
    );

void main() {
  test('a key imported is given the fingerprint the same key is given when made here, with no padding', () async {
    for (final type in [KeyType.ed25519, KeyType.ecdsaP256]) {
      final made = await KeyGenerationService().generate(type);
      final imported = KeyImportService().importOpenSSHKey(made.privatePem).fingerprint;
      expect(imported, made.fingerprint, reason: '$type');
      expect(imported, startsWith('SHA256:'));
      expect(imported, isNot(endsWith('=')));
    }
  });

  test('a fingerprint kept with padding is shown without it; any other as it is', () {
    expect(Redactable.fingerprint('SHA256:qZX7OwoVRHR5jo8zx6hUh6WccP7BHr6DBXN7rVCkxIE=').display,
        'SHA256:qZX7OwoVRHR5jo8zx6hUh6WccP7BHr6DBXN7rVCkxIE');
    expect(Redactable.fingerprint('SHA256:qZX7OwoVRHR5jo8zx6hUh6WccP7BHr6DBXN7rVCkxIE').display,
        'SHA256:qZX7OwoVRHR5jo8zx6hUh6WccP7BHr6DBXN7rVCkxIE');
    expect(Redactable.fingerprint('MD5:16:27:ac:a5:76:28:2d:36:63:1b:56:4d:eb:df:a6:48').display,
        'MD5:16:27:ac:a5:76:28:2d:36:63:1b:56:4d:eb:df:a6:48');
    expect(fingerprintAsShown('ab12='), 'ab12=', reason: 'not an SHA256 one');
  });

  test('one key kept with padding and without it is one key twice', () {
    final twice = duplicateIdentityIds([
      _key('a', 'SHA256:qZX7OwoVRHR5jo8zx6hUh6WccP7BHr6DBXN7rVCkxIE='),
      _key('b', 'SHA256:qZX7OwoVRHR5jo8zx6hUh6WccP7BHr6DBXN7rVCkxIE'),
      _key('c', 'SHA256:AnotherKeyAltogether00000000000000000000000'),
      _key('d', null),
    ]);
    expect(twice, {'a', 'b'});
  });
}
