import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/profiles/keychain.dart';
import 'package:zestssh/services/sync_service.dart';
import 'package:zestssh/services/vault_slot_service.dart';

/// The app lock with several profiles (to-do 60): the PIN opens a random vault
/// key, as ever, and the vault key wraps each profile's database key on its
/// own, with the hardware layer too when that is on. It is never one profile's
/// key that is "the lock's key": that would strand every other profile the
/// moment that one signed out.
///
/// The slots are the device's, under a new name ([KeychainNames.renamed]), and
/// the wraps are the profiles', so this works on the system's keychain itself.
class ProfileVault {
  ProfileVault(this._device);

  final FlutterSecureStorage _device;

  static String plainName(String id) => '${KeychainPrefix.of(id)}${KeychainNames.databaseKey}';
  static String wrappedName(String id) => '${KeychainPrefix.of(id)}${KeychainNames.wrappedDatabaseKey}';
  static String hardwareName(String id) => '${KeychainPrefix.of(id)}${KeychainNames.hardwareWrappedDatabaseKey}';

  static const slotsName = 'vault2_slots';
  static const hardwareOnName = 'vault2_hw_on';

  /// The vault's own entries, for what a name alone says.
  Future<bool> hasSlots() async => (await _device.read(key: slotsName)) != null;

  Future<bool> hardwareOn() async => (await _device.read(key: hardwareOnName)) != null;

  /// Whether the lock is on, decided as the app starts from what the keychain
  /// holds, and any half-finished turning on or off put right.
  ///
  /// The vault is never dropped while any profile's only copy is wrapped by
  /// it. It goes only where at least one profile has its plain key and none is
  /// held by the vault alone: then it is a turning on or off that stopped, and
  /// nothing needs it. (With no profile holding a key at all, the slots stay:
  /// the PIN is still the PIN.) A wrapped copy with no slots beside it can be
  /// opened by nothing: it goes where the plain key is there, and is left
  /// otherwise, for what cannot be undone is never done on a guess.
  ///
  /// Only which entries are there is asked, never what they hold (3.3.2): on a Mac
  /// a read of each may bring up macOS's question about the keychain, and every
  /// profile's key was read here, and the opening one's again as it opened.
  Future<bool> startUpCheck(Iterable<String> profiles) async {
    final names = (await keychainNamesIn(_device)).toSet();
    final slots = names.contains(slotsName);
    var heldByVaultAlone = false;
    var anyPlain = false;
    final withPlain = <String>[];
    for (final id in profiles) {
      final plain = names.contains(plainName(id));
      final wrapped = names.contains(wrappedName(id)) || names.contains(hardwareName(id));
      if (plain) {
        anyPlain = true;
        if (wrapped) withPlain.add(id);
      } else if (wrapped) {
        heldByVaultAlone = true;
      }
    }
    if (slots && heldByVaultAlone) return true;
    if (slots && !anyPlain) return true;
    // Nor while what waits for an account is wrapped by it.
    if (slots && await HeldEntries(_device).anyWrapped()) return true;
    for (final id in withPlain) {
      await _device.delete(key: wrappedName(id));
      await _device.delete(key: hardwareName(id));
    }
    if (slots) {
      await _device.delete(key: slotsName);
      await _device.delete(key: hardwareOnName);
    }
    return false;
  }

  /// Turns the lock on: every profile's wrapped copy is written first, then
  /// the slots, and only then are the plain keys deleted. [keys] is each
  /// profile's database key. Returns the vault key, kept in memory while the
  /// app is unlocked.
  Future<SecretKey> turnOn({required Map<String, String> keys, required VaultSlotService slots, required String pin}) async {
    final vaultKey = SyncService.generateDek();
    for (final entry in keys.entries) {
      await _writeWrap(entry.key, entry.value, vaultKey);
    }
    await slots.writeNewSlots(vaultKey: vaultKey, pin: pin);
    for (final id in keys.keys) {
      await _device.delete(key: plainName(id));
    }
    // Last, once the start-up check no longer drops the vault: what waits for
    // an account has no other copy, and a vault key that is gone would take it
    // along. A stop before this is finished at the next unlock.
    await _wrapHeld(vaultKey);
    return vaultKey;
  }

  /// Turns the lock off: every plain key first, then the vault. [hardwareKey]
  /// is required while the hardware layer is on.
  Future<void> turnOff({required Iterable<String> profiles, required SecretKey vaultKey, List<int>? hardwareKey}) async {
    // First, while the start-up check keeps the vault: what waits for an account
    // has no other copy. A stop in here is put right at the next unlock.
    await _unwrapHeld(vaultKey);
    final wrapped = <String>[];
    for (final id in profiles) {
      if (await _device.read(key: wrappedName(id)) == null && await _device.read(key: hardwareName(id)) == null) continue;
      final hex = await unwrap(id, vaultKey, hardwareKey: hardwareKey);
      await _device.write(key: plainName(id), value: hex);
      if (await _device.read(key: plainName(id)) != hex) throw StateError('A plain key did not read back');
      wrapped.add(id);
    }
    for (final id in wrapped) {
      await _device.delete(key: wrappedName(id));
      await _device.delete(key: hardwareName(id));
    }
    await _device.delete(key: slotsName);
    await _device.delete(key: hardwareOnName);
  }

  /// What a turning on that stopped left behind, once the app is unlocked: a
  /// plain key beside a copy that opens goes, and one with no copy gets its
  /// copy first. Only what opens to the same key is deleted.
  Future<void> settleAfterUnlock(Iterable<String> profiles, SecretKey vaultKey, {List<int>? hardwareKey}) async {
    for (final id in profiles) {
      final plain = await _device.read(key: plainName(id));
      if (plain == null) continue;
      final hasWrap = await _device.read(key: wrappedName(id)) != null || await _device.read(key: hardwareName(id)) != null;
      if (!hasWrap) await wrap(id, plain, vaultKey, hardwareKey: hardwareKey);
      if (await unwrap(id, vaultKey, hardwareKey: hardwareKey) == plain) {
        await _device.delete(key: plainName(id));
      }
    }
    await _wrapHeld(vaultKey);
  }

  /// [hex] as the profile [id]'s key with the lock on: wrapped by the vault
  /// key, and by the hardware layer while that is on.
  Future<void> wrap(String id, String hex, SecretKey vaultKey, {List<int>? hardwareKey}) async {
    await _writeWrap(id, hex, vaultKey);
    if (await hardwareOn()) {
      if (hardwareKey == null) throw const VaultLockedException('Hardware-backed encryption is on: device authentication required');
      final raw = (await _device.read(key: wrappedName(id)))!;
      final inner = await SyncService.wrapDek(SecretKey(base64Decode(raw)), SecretKey(hardwareKey));
      await _device.write(key: hardwareName(id), value: base64Encode(inner));
      await _device.delete(key: wrappedName(id));
    }
  }

  Future<void> _writeWrap(String id, String hex, SecretKey vaultKey) async {
    final wrapped = await SyncService.wrapDek(SecretKey(utf8.encode(hex)), vaultKey);
    await _device.write(key: wrappedName(id), value: base64Encode(wrapped));
    // Read back and opened before any plain key may go.
    final back = await _device.read(key: wrappedName(id));
    if (back == null) throw StateError('A wrapped key did not read back');
    final opened = await SyncService.unwrapDek(base64Decode(back), vaultKey);
    if (utf8.decode(await opened.extractBytes()) != hex) throw StateError('A wrapped key did not open');
  }

  /// The profile [id]'s key, from its wrap. The hardware copy is read first,
  /// as a stale plain wrap beside it must not skip the hardware.
  Future<String> unwrap(String id, SecretKey vaultKey, {List<int>? hardwareKey}) async {
    final hw = await _device.read(key: hardwareName(id));
    final String raw;
    if (hw != null) {
      if (hardwareKey == null) throw const VaultLockedException('Hardware-backed encryption is on: device authentication required');
      final inner = await SyncService.unwrapDek(base64Decode(hw), SecretKey(hardwareKey));
      raw = base64Encode(await inner.extractBytes());
    } else {
      final plain = await _device.read(key: wrappedName(id));
      if (plain == null) throw const VaultLockedException('No wrapped DB key');
      raw = plain;
    }
    final key = await SyncService.unwrapDek(base64Decode(raw), vaultKey);
    return utf8.decode(await key.extractBytes());
  }

  /// Turns the hardware layer on for every wrapped profile: its copy first,
  /// then the plain wrap goes, so at every moment one copy opens.
  Future<void> enableHardware(Iterable<String> profiles, List<int> hardwareKey) async {
    await _device.write(key: hardwareOnName, value: '1');
    for (final id in profiles) {
      final raw = await _device.read(key: wrappedName(id));
      if (raw == null) continue;
      final wrapped = await SyncService.wrapDek(SecretKey(base64Decode(raw)), SecretKey(hardwareKey));
      await _device.write(key: hardwareName(id), value: base64Encode(wrapped));
      await _device.delete(key: wrappedName(id));
    }
  }

  /// Turns the hardware layer off for every profile, in the same order.
  Future<void> disableHardware(Iterable<String> profiles, List<int> hardwareKey) async {
    for (final id in profiles) {
      final hw = await _device.read(key: hardwareName(id));
      if (hw == null) continue;
      final inner = await SyncService.unwrapDek(base64Decode(hw), SecretKey(hardwareKey));
      await _device.write(key: wrappedName(id), value: base64Encode(await inner.extractBytes()));
      await _device.delete(key: hardwareName(id));
    }
    await _device.delete(key: hardwareOnName);
  }

  /// The profile [id] signed out: its plain key and its copies the vault opens
  /// go. Only what ZestSSH Cloud's secret opens stays.
  Future<void> dropCopies(String id) async {
    await _device.delete(key: plainName(id));
    await _device.delete(key: wrappedName(id));
    await _device.delete(key: hardwareName(id));
  }

  Future<void> _wrapHeld(SecretKey vaultKey) async {
    await HeldEntries(_device).wrapAll(vaultKey);
  }

  Future<void> _unwrapHeld(SecretKey vaultKey) async {
    await HeldEntries(_device).unwrapAll(vaultKey);
  }
}

/// What waits for its account to sign in here: the secrets of the old layout
/// that belong to an account other than the one signed in at the move, and the
/// keys of teams no profile has yet. They were sealed by a seal that is now one
/// profile's, or plain: each is opened at the move and kept here, in an entry
/// whose name says nothing of whose it is, wrapped by the vault key while the
/// app lock is on.
class HeldEntries {
  HeldEntries(this._device);

  final FlutterSecureStorage _device;

  static const prefix = 'held.';
  static const _wrappedMark = 'zheld1:';
  static final _aes = AesGcm.with256bits();

  static String _entry(String name) => '$prefix${hash.sha256.convert(utf8.encode(name)).toString().substring(0, 32)}';

  /// Keeps [value], the secret the old layout called [name].
  Future<void> put(String name, String value, {SecretKey? vaultKey}) async {
    final kept = vaultKey == null ? value : await _wrap(name, value, vaultKey);
    final entry = _entry(name);
    final raw = jsonEncode({'name': name, 'value': kept});
    await _device.write(key: entry, value: raw);
    if (await _device.read(key: entry) != raw) throw StateError('A held secret did not read back');
  }

  /// The secret the old layout called [name], or null. Throws [VaultLockedException]
  /// where it is wrapped and [vaultKey] is not given.
  Future<String?> read(String name, {SecretKey? vaultKey}) async {
    final raw = await _device.read(key: _entry(name));
    if (raw == null) return null;
    return _open(name, (jsonDecode(raw) as Map)['value'] as String, vaultKey);
  }

  Future<void> remove(String name) => _device.delete(key: _entry(name));

  /// Every name held.
  Future<List<String>> names() async {
    final out = <String>[];
    for (final e in (await keychainEntriesIn(_device, (name) => name.startsWith(prefix))).entries) {
      try {
        out.add((jsonDecode(e.value) as Map)['name'] as String);
      } catch (_) {/* not one of ours */}
    }
    return out;
  }

  /// Whether any is wrapped, which only the vault key opens.
  Future<bool> anyWrapped() async {
    for (final e in (await keychainEntriesIn(_device, (name) => name.startsWith(prefix))).entries) {
      try {
        if (((jsonDecode(e.value) as Map)['value'] as String).startsWith(_wrappedMark)) return true;
      } catch (_) {/* not one of ours */}
    }
    return false;
  }

  Future<void> wrapAll(SecretKey vaultKey) async {
    for (final name in await names()) {
      final raw = await _device.read(key: _entry(name));
      final value = (jsonDecode(raw!) as Map)['value'] as String;
      if (value.startsWith(_wrappedMark)) continue;
      await put(name, value, vaultKey: vaultKey);
    }
  }

  Future<void> unwrapAll(SecretKey vaultKey) async {
    for (final name in await names()) {
      final value = await read(name, vaultKey: vaultKey);
      if (value != null) await put(name, value);
    }
  }

  static Future<String> _wrap(String name, String value, SecretKey vaultKey) async {
    final box = await _aes.encrypt(utf8.encode(value), secretKey: vaultKey, aad: utf8.encode(name));
    return '$_wrappedMark${base64.encode(box.concatenation())}';
  }

  static Future<String> _open(String name, String kept, SecretKey? vaultKey) async {
    if (!kept.startsWith(_wrappedMark)) return kept;
    if (vaultKey == null) throw const VaultLockedException('The app lock is on: unlock first');
    final bytes = Uint8List.fromList(base64.decode(kept.substring(_wrappedMark.length)));
    final box = SecretBox.fromConcatenation(bytes,
        nonceLength: _aes.nonceLength, macLength: _aes.macAlgorithm.macLength, copy: false);
    return utf8.decode(await _aes.decrypt(box, secretKey: vaultKey, aad: utf8.encode(name)));
  }
}
