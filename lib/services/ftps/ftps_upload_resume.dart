// Uploads to an FTPS server that broke off with the connection, kept across a restart of the app
// (3.4), so the same upload again goes on from what the server has in its `.zestpart` rather than
// from the start.
//
// Kept in the preferences of the profile that is open (its database on a computer, so another
// profile neither sees nor goes on with them), on this device only, and nothing readable: each
// entry is found by a SHA-256 of the server, account and path, and holds a SHA-256 of the local
// file's path with its size and time (the same file, unchanged, is all that may go on). Entries
// older than a week go, and at most [FtpsUploadResume.maxEntries] are kept.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/services/profiles/profile_preferences.dart';

/// One upload that broke off: which file of this device (by a hash of its path), at which size and
/// time, and when it broke off.
class FtpsBrokenUpload {
  const FtpsBrokenUpload({required this.localHash, required this.size, required this.modifiedMs, required this.atMs});

  final String localHash;
  final int size;
  final int modifiedMs;
  final int atMs;

  Map<String, Object> toJson() => {'l': localHash, 's': size, 'm': modifiedMs, 't': atMs};

  static FtpsBrokenUpload? fromJson(Object? json) {
    if (json is! Map) return null;
    final l = json['l'], s = json['s'], m = json['m'], t = json['t'];
    if (l is! String || s is! int || m is! int || t is! int) return null;
    return FtpsBrokenUpload(localHash: l, size: s, modifiedMs: m, atMs: t);
  }

  /// Whether [localPath], now [size] bytes modified at [modified], is the file that broke off.
  bool isOf(String localPath, int size, DateTime modified) =>
      localHash == FtpsUploadResume.hashOf(localPath) && this.size == size && modifiedMs == modified.millisecondsSinceEpoch;
}

/// The store of [FtpsBrokenUpload]s, in the preferences under [prefsKey].
class FtpsUploadResume {
  FtpsUploadResume({Future<SharedPreferences> Function()? prefs, DateTime Function()? now})
      : _prefs = prefs ?? appPreferences,
        _now = now ?? DateTime.now;

  /// The preference key (SettingsService.keptKeys: the app's own work, no setting; and
  /// SettingsService.profileKeys: the open profile's, read through [appPreferences]).
  static const prefsKey = 'ftps_partial_uploads';

  /// The most entries kept; the oldest go first.
  static const maxEntries = 100;

  /// How long an entry is kept.
  static const keepFor = Duration(days: 7);

  final Future<SharedPreferences> Function() _prefs;
  final DateTime Function() _now;

  /// The SHA-256 of [text], in hex.
  static String hashOf(String text) => sha256.convert(utf8.encode(text)).toString();

  /// The key of the upload to [stagedPath] on [user]@[host]:[port].
  static String keyOf({required String host, required int port, required String user, required String stagedPath}) =>
      hashOf('$user@$host:$port|$stagedPath');

  Future<Map<String, FtpsBrokenUpload>> _read(SharedPreferences prefs) async {
    final raw = prefs.getString(prefsKey);
    if (raw == null) return {};
    final out = <String, FtpsBrokenUpload>{};
    try {
      final json = jsonDecode(raw);
      if (json is Map) {
        final oldest = _now().subtract(keepFor).millisecondsSinceEpoch;
        for (final e in json.entries) {
          final u = FtpsBrokenUpload.fromJson(e.value);
          if (u != null && e.key is String && u.atMs >= oldest) out[e.key as String] = u;
        }
      }
    } catch (_) {
      // A store that does not read is no store: started again.
    }
    return out;
  }

  Future<void> _write(SharedPreferences prefs, Map<String, FtpsBrokenUpload> all) async {
    if (all.isEmpty) {
      await prefs.remove(prefsKey);
      return;
    }
    final kept = all.entries.toList()..sort((a, b) => b.value.atMs.compareTo(a.value.atMs));
    await prefs.setString(prefsKey, jsonEncode({for (final e in kept.take(maxEntries)) e.key: e.value.toJson()}));
  }

  /// Notes that the upload [key] of [localPath] ([size] bytes, modified at [modified]) broke off.
  Future<void> remember(String key, {required String localPath, required int size, required DateTime modified}) async {
    final prefs = await _prefs();
    final all = await _read(prefs);
    all[key] = FtpsBrokenUpload(
      localHash: hashOf(localPath),
      size: size,
      modifiedMs: modified.millisecondsSinceEpoch,
      atMs: _now().millisecondsSinceEpoch,
    );
    await _write(prefs, all);
  }

  /// The upload [key] that broke off, taken out of the store (whatever comes of it now, it is
  /// noted again only if it breaks off again).
  Future<FtpsBrokenUpload?> take(String key) async {
    final prefs = await _prefs();
    final all = await _read(prefs);
    final found = all.remove(key);
    await _write(prefs, all);
    return found;
  }
}
