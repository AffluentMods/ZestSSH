import 'dart:isolate';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/providers/core_providers.dart' show identitySecretsProvider;
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/utils/type_name.dart';

// A key's passphrase (3.0, Keys, PROTECTION: "Passphrase:
// None · Add one"). Whether a key has one is shown without the key being
// read: it is kept on the device when the key is saved, and when its editor
// loads it ([KeyPassphraseFlags]); a key the device has not seen saved shows
// that it is not known yet. Adding, changing or taking off a passphrase
// writes the private key again as an OpenSSH file (the core's
// OpenSSHKeyFile: bcrypt_pbkdf and aes256-ctr, as ssh-keygen -p does), and
// sync carries that file as it carries any key.
//
// Connecting is as it was: where the passphrase is kept with the key (the
// default, as a key imported with its passphrase is), a connection opens the
// key with it and asks nothing; where it is not kept, a connection asks for
// it, as for any key whose passphrase is not saved.

/// Whether keys have a passphrase, as this device last saw them
/// (`key_passphrase:<id>`: `set` or `none`, in its own encrypted state).
class KeyPassphraseFlags {
  KeyPassphraseFlags(this._open);

  /// The device's own store; it can throw (a locked database, a test
  /// with none), and then nothing is known or kept.
  final LocalStateStore Function() _open;

  static const prefix = 'key_passphrase:';

  /// Each key's, by its id: true where it has a passphrase.
  Future<Map<String, bool>> all() async {
    final out = <String, bool>{};
    try {
      final store = _open();
      for (final k in await store.keysWithPrefix(prefix)) {
        final v = await store.read(k);
        if (v == 'set' || v == 'none') out[k.substring(prefix.length)] = v == 'set';
      }
    } catch (_) {
      // Nothing known: the details say it is not checked yet.
    }
    return out;
  }

  Future<void> remember(String identityId, {required bool sealed}) async {
    try {
      await _open().write('$prefix$identityId', sealed ? 'set' : 'none');
    } catch (_) {
      // Not kept: the details say it is not checked yet.
    }
  }

  /// [pem]'s state remembered for [identityId] (nothing where it cannot be
  /// read as a key file).
  Future<void> rememberOf(String identityId, String? pem) async {
    final sealed = pemIsSealed(pem);
    if (sealed != null) await remember(identityId, sealed: sealed);
  }

  Future<void> forget(String identityId) async {
    try {
      await _open().remove('$prefix$identityId');
    } catch (_) {/* nothing kept */}
  }
}

final keyPassphraseFlagsProvider = Provider<KeyPassphraseFlags>((ref) => KeyPassphraseFlags(() => ref.read(localStateStoreProvider)));

/// Each key's passphrase state as the device knows it ([KeyPassphraseFlags]).
final keyPassphraseStatesProvider =
    FutureProvider.autoDispose<Map<String, bool>>((ref) => ref.watch(keyPassphraseFlagsProvider).all());

/// Whether [pem] is sealed under a passphrase; null where it is no key file.
bool? pemIsSealed(String? pem) {
  if (pem == null || pem.trim().isEmpty) return null;
  try {
    return SSHKeyPair.isEncryptedPem(pem);
  } catch (_) {
    return null;
  }
}

/// What changing a passphrase could not do.
enum PassphraseChangeRefusal {
  /// The key is sealed and its passphrase was neither given nor kept.
  needsCurrent,

  /// The passphrase given does not open it.
  wrongCurrent,

  /// There is no private key, or none that can be written again.
  noKey,
}

class PassphraseChangeFailed implements Exception, HasTypeName {
  const PassphraseChangeFailed(this.why, [this.cause]);

  final PassphraseChangeRefusal why;
  final Object? cause;

  @override
  String get typeName => 'PassphraseChangeFailed';

  @override
  String toString() => 'PassphraseChangeFailed(${why.name}${cause == null ? '' : ': $cause'})';
}

/// [pem] written again under [next] (null or empty: no passphrase), opened
/// with [current], off the screen's thread (bcrypt_pbkdf takes a moment),
/// and checked: the file written opens with [next] as the same key.
Future<String> resealPrivateKey(String pem, {String? current, String? next}) async {
  final String written;
  try {
    written = await Isolate.run(() => OpenSSHKeyFile.rewrite(pem, passphrase: current, newPassphrase: next));
  } on SSHKeyDecryptError catch (e) {
    throw PassphraseChangeFailed(
        current == null || current.isEmpty ? PassphraseChangeRefusal.needsCurrent : PassphraseChangeRefusal.wrongCurrent, e);
  } on SSHKeyDecodeError catch (e) {
    throw PassphraseChangeFailed(PassphraseChangeRefusal.wrongCurrent, e);
  } catch (e) {
    throw PassphraseChangeFailed(PassphraseChangeRefusal.noKey, e);
  }
  final sealed = next != null && next.isNotEmpty;
  final was = SSHKeyPair.fromPem(pem, pemIsSealed(pem) == true ? current : null).first.toPublicKey().encode();
  final now = SSHKeyPair.fromPem(written, sealed ? next : null).first.toPublicKey().encode();
  if (was.length != now.length || [for (var i = 0; i < was.length; i++) was[i] == now[i]].contains(false)) {
    throw const PassphraseChangeFailed(PassphraseChangeRefusal.noKey);
  }
  return written;
}

/// Adds, changes and takes off keys' passphrases.
class KeyPassphraseService {
  KeyPassphraseService(this._ref);

  final Ref _ref;

  /// How the key [key] is kept now: its private key, and the passphrase
  /// kept with it (null where none is).
  Future<({String? pem, String? kept})> keptKeyOf(Identity key) async {
    final crud = _ref.read(identityCrudProvider);
    return (pem: await crud.getPrivateKey(key.id), kept: await crud.getKeyPassphrase(key.id));
  }

  /// Gives [key] the passphrase [next] (null: none), opened with [current]
  /// or, where none is given, with the passphrase kept with it. With
  /// [keepWithKey], [next] is kept with the key (connecting asks nothing);
  /// without, no passphrase is kept and connecting asks for it. Writes the
  /// key, and what the device knows of it ([KeyPassphraseFlags]).
  Future<void> change(
    Identity key, {
    String? current,
    String? next,
    bool keepWithKey = true,
  }) async {
    final ref = _ref;
    final (:pem, :kept) = await keptKeyOf(key);
    if (pem == null || pem.isEmpty) throw const PassphraseChangeFailed(PassphraseChangeRefusal.noKey);
    final sealed = pemIsSealed(pem) ?? false;
    final opener = sealed ? ((current != null && current.isNotEmpty) ? current : kept) : null;
    if (sealed && (opener == null || opener.isEmpty)) {
      throw const PassphraseChangeFailed(PassphraseChangeRefusal.needsCurrent);
    }
    final nextGiven = next != null && next.isNotEmpty ? next : null;
    final written = await resealPrivateKey(pem, current: opener, next: nextGiven);
    // The passphrase kept with the key first: the new one where it is to be
    // kept, else none (an open key with a passphrase kept beside it does not
    // open). Then the key, as the editor saves one, so the change is synced
    // as a key edited there is.
    await ref.read(identitySecretsProvider).write(
        key.id, IdentitySecret.passphrase, nextGiven != null && keepWithKey ? nextGiven : null);
    await ref.read(identityCrudProvider).update(id: key.id, privateKeyPem: written);
    await ref.read(keyPassphraseFlagsProvider).remember(key.id, sealed: nextGiven != null);
    ref.invalidate(keyPassphraseStatesProvider);
  }
}

final keyPassphraseServiceProvider = Provider<KeyPassphraseService>(KeyPassphraseService.new);
