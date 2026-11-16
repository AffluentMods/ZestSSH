import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/sync_service.dart';

/// What the app says of sync data it cannot open (3.0).
///
/// Its details end with the kind of failure, and with nothing of the data
/// (the SSH core's audit, the app's half of what it found of names): after
/// the data is decrypted, what fails is the reading of it, and such an error
/// can quote a piece of what it read. So they name the kind of error, which
/// asked the program for the name of the type (`runtimeType`) before:
/// another name in a build made for release, "(aB)".
///
/// What the person reads is said in their language (it was
/// that English sentence, in every language, and the screens put it on the
/// sync card as it was): the data was locked with another password or key,
/// or changed since; it is damaged; or it is larger than the app opens.
void main() {
  final de = lookupAppLocalizations(const Locale('de'));
  const lead = 'Decryption failed - sync data may be corrupted or tampered with. '
      'If this persists, try restoring from a backup. ';

  setUp(() => L10nGlobal.update(de));
  tearDown(() => L10nGlobal.update(lookupAppLocalizations(const Locale('en'))));

  Future<SecretKey> key(int seed) async => SecretKey(List<int>.generate(32, (i) => (i * 7 + seed) & 0xff));

  /// [inner], encrypted with [with_] as sync data is laid out: salt (32),
  /// nonce (12), tag (16), then the encrypted bytes.
  Future<Uint8List> packed(List<int> inner, SecretKey with_) async {
    final box = await AesGcm.with256bits().encrypt(inner, secretKey: with_);
    return Uint8List.fromList([...List<int>.filled(32, 1), ...box.nonce, ...box.mac.bytes, ...box.cipherText]);
  }

  Future<SyncDecryptionException> thrown(Future<Object?> Function() step) async {
    try {
      await step();
    } on SyncDecryptionException catch (e) {
      return e;
    }
    return fail('it was opened');
  }

  /// What the details say of [package] opened with [with_].
  Future<String> said(Uint8List package, SecretKey with_) async =>
      (await thrown(() => SyncService.decrypt(package, with_))).detail!;

  test('the wrong key, or data that was changed: the check of the encryption failed', () async {
    final package = await SyncService.encrypt({'hosts': <Object>[]}, await key(1), Uint8List(32));
    final other = await key(2);
    expect(await said(package, other), '$lead(SecretBoxAuthenticationError)');
    expect((await thrown(() => SyncService.decrypt(package, other))).message, de.syncDataNotOpened);
    package[package.length - 1] ^= 1;
    expect(await said(package, await key(1)), '$lead(SecretBoxAuthenticationError)');
  });

  test('data that opens and is not what sync writes: the kind of what failed, by its name and not by what the '
      'program calls it, and nothing of the data; said as damaged', () async {
    final k = await key(1);
    // Not compressed at all.
    final plain = await packed(utf8.encode('{"password":"hunter2-not-a-real-one"}'), k);
    expect(await said(plain, k), '$lead(FormatException)');
    expect((await thrown(() => SyncService.decrypt(plain, k))).message, de.syncDataDamaged);
    // Compressed, and no JSON.
    expect(await said(await packed(zlib.encode(utf8.encode('password: hunter2-not-a-real-one')), k), k),
        '$lead(FormatException)');
    // JSON, and a list where an object belongs: a cast that fails. (The program's name for that kind starts with
    // an underscore in a test.)
    expect(await said(await packed(zlib.encode(utf8.encode('["hunter2-not-a-real-one"]')), k), k), '$lead(TypeError)');
  });

  test('data that is too short to be sync data: damaged; and data that is right opens as before', () async {
    final short = await thrown(() async => SyncService.decrypt(Uint8List(59), await key(1)));
    expect(short.message, de.syncDataDamaged);
    expect(short.detail, 'Encrypted data is too short - data may be corrupted');
    final k = await key(1);
    final package = await SyncService.encrypt({'hosts': <Object>[], 'n': 3}, k, Uint8List(32));
    expect(await SyncService.decrypt(package, k), {'hosts': <Object>[], 'n': 3});
  });

  test('a data key the password does not open, and one too short to be one', () async {
    final wrapped = await SyncService.wrapDek(SyncService.generateDek(), await key(1));
    final other = await key(2);
    final wrong = await thrown(() => SyncService.unwrapDek(wrapped, other));
    expect(wrong.message, de.syncDataNotOpened);
    expect(wrong.detail, 'Failed to unwrap data key - wrong password or data tampered.');
    final short = await thrown(() => SyncService.unwrapDek(Uint8List(59), other));
    expect(short.message, de.syncDataDamaged);
    expect(short.detail, 'Wrapped DEK is too short - data may be corrupted');
  });

  test('more than the app opens is said as that, and not opened', () async {
    final k = await key(1);
    final bomb = await packed(zlib.encode(Uint8List(64 * 1024 * 1024 + 1)), k);
    final said = await thrown(() => SyncService.decrypt(bomb, k));
    expect(said.message, de.syncDataTooLargeToOpen);
    expect(said.detail, 'Decompressed sync data exceeds the safe maximum - refusing to load.');
  });
}
