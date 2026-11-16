import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show SecretKey;
import 'package:path_provider/path_provider.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/secret_seal.dart' show KeySecretUnread;
import 'package:zestssh/services/sync/sync_failure.dart';
import 'package:zestssh/services/sync_data_service.dart';
import 'package:zestssh/services/sync_service.dart';
import 'package:zestssh/utils/android_save_folder.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/services/profiles/active_profile.dart';

/// Result of a backup export or import operation.
class BackupResult {
  final bool success;
  final String? filePath;
  final int recordCount;

  /// Why it failed, in the app's language.
  final String? error;

  /// The password was wrong, or an encrypted backup was given none: the
  /// person is asked for it again. (3.0: the import looked for
  /// the English word "password" in [error], which is in the app's
  /// language, so in German or Japanese a wrong password ended the import.)
  final bool passwordWrong;

  /// What was thrown, or what the restore said, for the report of the
  /// notice that says [error]; null when [error] says it all.
  final String? detail;

  /// True when an unencrypted legacy (v2) backup was imported.
  /// The UI should warn the user to re-export with a password.
  final bool legacyUnencrypted;

  /// The person was shown what it would restore and said no: nothing was
  /// written.
  final bool cancelled;

  const BackupResult({
    required this.success,
    this.filePath,
    this.recordCount = 0,
    this.error,
    this.passwordWrong = false,
    this.detail,
    this.legacyUnencrypted = false,
    this.cancelled = false,
  });
}

/// Handles local .zest backup files.
///
/// All backups are encrypted with AES-256-GCM using a key derived from
/// a user-supplied password via Argon2id (same parameters as cloud sync).
/// A blank password is refused by default: exporting an unencrypted dump
/// of someone's SSH credentials, identities, and known_hosts would be
/// catastrophic if the device is shared, lost, synced to OneDrive, or
/// scanned by another app with storage access. Producing a plaintext (v2)
/// backup requires an explicit `allowUnencrypted: true` opt-in that no
/// normal UI path sets. Legacy v2 files are still *read* on import for
/// backward compatibility.
///
/// This is a FREE feature - not paywalled.
class BackupService {
  /// Minimum password length for backup encryption.
  /// Backups land in user-accessible storage (Downloads, Files app),
  /// so the password is the only thing standing between the file and
  /// an offline attacker.
  static const int minBackupPasswordLength = 12;

  /// Whether a `.zest` file's bytes are a password-protected backup, so a caller
  /// knows to prompt for the password BEFORE calling [importBackup]. Recognises
  /// both encrypted formats: v1 (legacy AES-GCM) and v3 (AES-GCM + embedded KDF
  /// params, the format exported today). v2 is unencrypted. This is the SINGLE
  /// source of truth - inline `bytes[4] == 1` checks drifted and skipped v3,
  /// which is exactly what stranded the import-password prompt.
  /// The largest backup a restore reads: a larger file is refused before it is
  /// read into memory (a multi-gigabyte `.zest` would run the app out of it).
  static const maxBackupBytes = 50 * 1024 * 1024;

  /// The least an encrypted backup holds after its header: the salt (32
  /// bytes), the nonce (12) and the tag (16) of what it seals.
  static const leastSealed = 60;

  /// The end of a backup's name while it is written, before it is given its
  /// own ([exportBackup]).
  static const unfinishedSuffix = '.part';

  /// Backups whose writing never finished (the app stopped in the middle),
  /// older than an hour, in [dir]: deleted. One being written now is newer.
  static Future<void> _dropUnfinished(Directory dir) async {
    try {
      final before = DateTime.now().subtract(const Duration(hours: 1));
      for (final f in dir.listSync().whereType<File>()) {
        final name = f.uri.pathSegments.last;
        if (name.startsWith('zestssh_') && name.endsWith('.zest$unfinishedSuffix') && f.lastModifiedSync().isBefore(before)) {
          await f.delete();
        }
      }
    } catch (e) {
      AppLogger.warning('Unfinished backups not cleared: ${errorKind(e)}');
    }
  }

  /// The details of a file of [size] bytes refused for its size.
  static String tooLargeDetail(int size) => 'The file is $size bytes; the most a restore reads is $maxBackupBytes.';

  static bool isEncryptedBackup(List<int> bytes) =>
      bytes.length >= 5 && (bytes[4] == 1 || bytes[4] == 3);

  /// Whether a `.zest` file's bytes are a backup of any version (they start
  /// "ZEST" and a version), and not a host shared as a file, which is a
  /// `.zest` file as well, nor a text that only starts with those letters: a
  /// version is a byte below any that text has, a later version's too.
  static bool isBackupFile(List<int> bytes) =>
      bytes.length >= 5 &&
      bytes[0] == 0x5a &&
      bytes[1] == 0x45 &&
      bytes[2] == 0x53 &&
      bytes[3] == 0x54 &&
      bytes[4] >= 1 &&
      bytes[4] < 0x09;

  final SyncDataService _syncDataService;

  BackupService(this._syncDataService);

  /// Your Tree's database, which a backup is made from: its seal opens the
  /// automatic backups' password where the encrypting lock sealed it
  /// (AutoBackupService.readPassword).
  AppDatabase get sealedBy => _syncDataService.database;

  /// The directory a backup is written to - the SINGLE source of truth so the
  /// auto-backup cleanup scans exactly where exports land. A past bug had the
  /// desktop cleanup checking a different directory than exports were written
  /// to, so the retention cap never fired and encrypted secret dumps piled up
  /// without bound. Keep this the only place the path is computed.
  ///
  /// Mobile writes to a user-visible location (Android Downloads, iOS
  /// Documents/Files); on desktop, unattended auto-backups go to the private
  /// app-support dir (NOT the OneDrive/iCloud-synced Documents folder), while
  /// user-initiated exports go to Documents where the user can find them.
  static Future<Directory> resolveBackupDir(
      {required bool isAutoBackup}) async {
    if (Platform.isAndroid) {
      // The Download folder where Android lets the app write there, else
      // the app's own folder (androidSaveFolder: Android 8 to 10).
      return androidSaveFolder();
    }
    if (Platform.isIOS) {
      return getApplicationDocumentsDirectory();
    }
    final base = isAutoBackup
        ? await getApplicationSupportDirectory()
        : await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/ZestSSH/backups');
    // Automatic backups are each profile's own; a backup the person exported is
    // their file, where they find it.
    return isAutoBackup ? ProfilePaths.forCurrent(dir) : dir;
  }

  /// Export all app data to a .zest backup file.
  ///
  /// The backup contains every SSH credential, private key, and identity,
  /// so it is encrypted with AES-256-GCM (v1) using an Argon2id-derived
  /// key. A blank [password] is REFUSED by default - writing an
  /// unencrypted (v2) dump of the user's SSH secrets to disk is the kind
  /// of catastrophic exposure this guard exists to prevent. Producing a
  /// plaintext backup requires the caller to explicitly pass
  /// [allowUnencrypted] `true` (which no normal UI path sets), and is only
  /// intended behind a deliberate, clearly-worded confirmation.
  ///
  /// [filenamePrefix] defaults to `'zestssh_backup_'` for manual backups.
  /// Auto-backups pass `'zestssh_auto_'` so cleanup can distinguish them.
  ///
  /// Returns the file path on success.
  Future<BackupResult> exportBackup(
    String password, {
    String filenamePrefix = 'zestssh_backup_',
    bool allowUnencrypted = false,
  }) async {
    try {
      // Secure default: never emit an unencrypted backup unless a caller
      // has explicitly opted in. This closes the "leave the password blank"
      // path that used to silently write every SSH key as plaintext.
      if (password.isEmpty && !allowUnencrypted) {
        return BackupResult(
          success: false,
          error: gl10n.backupSvcPasswordRequired,
        );
      }

      // Gather all data
      // (A backup is no state of the store: it holds no count of it.)
      final data = SyncDataService.withoutStoreCount(await _syncDataService.gatherAll());
      final recordCount = _countRecords(data);

      // Resolve the target dir via the single source of truth so auto-backup
      // cleanup scans exactly where we write.
      final isAutoBackup = filenamePrefix.contains('auto');
      final backupDir = await resolveBackupDir(isAutoBackup: isAutoBackup);
      if (!backupDir.existsSync()) {
        backupDir.createSync(recursive: true);
      }

      // Named to the millisecond (3.4.2 sweep, L7: to the second, two in the
      // same second wrote one over the other), and never over one that is
      // there.
      final now = DateTime.now();
      final timestamp = '${now.toIso8601String().replaceAll(':', '-').split('.').first}'
          '-${now.millisecond.toString().padLeft(3, '0')}';
      var file = File('${backupDir.path}/$filenamePrefix$timestamp.zest');
      for (var n = 2; file.existsSync(); n++) {
        file = File('${backupDir.path}/$filenamePrefix$timestamp-$n.zest');
      }
      await _dropUnfinished(backupDir);

      // Magic + version byte + payload.
      // - v1 = AES-256-GCM encrypted, NO recorded KDF params (legacy; read-only)
      // - v2 = unencrypted JSON (legacy; read-only, refused on import by default)
      // - v3 = AES-256-GCM encrypted WITH the Argon2id params recorded in a
      //        JSON header, so raising the default cost later can never make an
      //        old backup undecryptable (v1's exact failure mode).
      final output = BytesBuilder();
      output.add(utf8.encode('ZEST')); // 4-byte magic
      if (password.isEmpty) {
        output.addByte(2); // version 2 = unencrypted JSON
        output.add(utf8.encode(jsonEncode(data)));
      } else {
        output.addByte(3); // version 3 = encrypted + embedded KDF params
        final salt = SyncService.generateSalt();
        final params = SyncService.argon2Params;
        final mek = await SyncService.deriveKey(password, salt, params: params);
        final encrypted = await SyncService.encrypt(data, mek, salt);
        final header = utf8.encode(jsonEncode(params));
        // 2-byte big-endian header length, then header, then blob.
        output.addByte((header.length >> 8) & 0xff);
        output.addByte(header.length & 0xff);
        output.add(header);
        output.add(encrypted);
      }

      // Written whole beside it first, then given its name (3.4.2 sweep, L7):
      // written in place, a crash or a phone suspended in the middle left a
      // newest backup cut short, which the rotation counted as good.
      final part = File('${file.path}$unfinishedSuffix');
      try {
        await part.writeAsBytes(output.toBytes(), flush: true);
        await part.rename(file.path);
      } catch (_) {
        try {
          if (part.existsSync()) await part.delete();
        } catch (_) {
          // (Left for the next backup's clean-up.)
        }
        rethrow;
      }

      AppLogger.info(
          '${password.isEmpty ? "Unencrypted" : "Encrypted"} backup exported: '
          '${file.path} ($recordCount records)');
      return BackupResult(
        success: true,
        filePath: file.path,
        recordCount: recordCount,
      );
    } on KeySecretUnread catch (e) {
      // A key whose saved secret does not open here: no backup is written
      // that would hold the key without it, and the person is told which
      // key and what to do.
      AppLogger.error('Backup export stopped: the secret of a key does not open here', e);
      return BackupResult(success: false, error: SyncFailure.keySecretUnread(e), detail: '$e (${e.slot})');
    } catch (e) {
      AppLogger.error('Backup export failed', e);
      // Said in the app's language; what was thrown is for the report (it
      // was the whole message, raw).
      return BackupResult(success: false, error: gl10n.backupSvcCouldNotWrite, detail: '$e');
    }
  }

  /// Import data from a .zest backup file.
  ///
  /// Only encrypted (v1) backups are supported. Legacy unencrypted (v2)
  /// backups produced by an older build are read for backward
  /// compatibility but are NOT created by this service.
  /// Adds and writes over, and deletes nothing here: the backup's tombstones
  /// are not taken, and what it holds comes back though it was deleted here
  /// since ([SyncDataService.restoreAll] with asBackup).
  Future<BackupResult> importBackup(
    String filePath,
    String password, {
    /// Legacy unencrypted (v2) backups are unauthenticated - anyone could have
    /// altered their contents (e.g. a `startupCommand`) before you imported.
    /// They are REFUSED unless the caller explicitly opts in AFTER showing a
    /// clear warning. No normal path sets this.
    bool allowLegacyUnencrypted = false,

    /// Shown what the backup would do before anything is written
    /// ([SyncDataService.previewRestore]); null restores nothing. The settings
    /// it would weaken stay as they are here unless the answer names them
    /// ([RestoreChoice]); with nobody asked, they all stay.
    Future<RestoreChoice?> Function(RestorePreview preview)? confirm,
  }) async {
    try {
      final file = File(filePath);
      if (!file.existsSync()) {
        return BackupResult(
          success: false,
          error: gl10n.backupSvcFileNotFound,
        );
      }

      // Security: reject oversized files before loading into memory to
      // prevent OOM from malicious multi-gigabyte .zest files.
      final fileSize = await file.length();
      if (fileSize > maxBackupBytes) {
        return BackupResult(
          success: false,
          error: gl10n.backupSvcFileTooLarge,
          detail: tooLargeDetail(fileSize),
        );
      }

      final bytes = await file.readAsBytes();

      // What stops a backup from opening is said as what it is (3.4.2: all
      // of it was "wrong password or corrupted backup", with nothing to copy),
      // each with what was found for the details.
      final kind = BackupService.kindOf(bytes);
      if (kind != null) return BackupResult(success: false, error: kind.said, detail: kind.detail);

      final version = bytes[4];
      final isLegacyUnencrypted = version == 2;

      Map<String, dynamic> data;

      if (version == 2) {
        // Legacy unencrypted JSON - unauthenticated. Refuse unless the caller
        // explicitly opted in after warning the user; a tampered v2 file could
        // carry a hostile startupCommand or an auto-run snippet.
        if (!allowLegacyUnencrypted) {
          return BackupResult(
            success: false,
            error: gl10n.backupSvcLegacyUnencryptedRefused,
          );
        }
        AppLogger.warning(
            'Importing legacy unencrypted backup - re-export immediately '
            'with a password.');
        final jsonStr = utf8.decode(bytes.sublist(5));
        data = jsonDecode(jsonStr) as Map<String, dynamic>;
      } else if (version == 1) {
        // Legacy encrypted, NO recorded KDF params. Derive with the CURRENT
        // default, and on failure retry with the legacy 64 MB params - this is
        // what recovers backups made before the default was raised to 128 MB
        // (raising it silently broke every param-less v1 file).
        if (password.isEmpty) {
          return BackupResult(
            success: false,
            error: gl10n.backupSvcPasswordProtected,
            passwordWrong: true,
          );
        }
        final encrypted = Uint8List.sublistView(bytes, 5);
        final opened = await _decryptWithFallback(encrypted, password, [
          null, // current default
          SyncService.legacyArgon2Params, // pre-v2 64 MB
        ], about: 'version 1 (no key derivation settings kept), ${bytes.length} bytes');
        if (opened.data == null) return opened.refused!;
        data = opened.data!;
      } else {
        // Version 3: encrypted WITH embedded KDF params ([kindOf] let no other
        // through). Derive with the recorded params (clamped defensively
        // inside deriveKey).
        if (password.isEmpty) {
          return BackupResult(
            success: false,
            error: gl10n.backupSvcPasswordProtected,
            passwordWrong: true,
          );
        }
        final headerLen = (bytes[5] << 8) | bytes[6];
        final params = _header(bytes)!;
        final encrypted = Uint8List.sublistView(bytes, 7 + headerLen);
        final opened = await _decryptWithFallback(encrypted, password, [params],
            about: 'version 3, ${bytes.length} bytes, key derivation ${_paramsText(params)}');
        if (opened.data == null) return opened.refused!;
        data = opened.data!;
      }

      var take = const <String>{};
      var takeHostKeys = false;
      if (confirm != null) {
        final answer = await confirm(await _syncDataService.previewRestore(data));
        if (answer == null) return const BackupResult(success: false, cancelled: true);
        take = answer.takeSettings;
        takeHostKeys = answer.takeHostKeys;
      }
      // What would turn down safety stays as it is here unless it was ticked.
      // Only here: a pull from the person's own account goes straight to
      // restoreAll, and takes it as their other devices have it.
      final settings = data['settings'];
      if (settings is Map) {
        for (final key in _syncDataService.settingsThatWeaken(settings)) {
          if (!take.contains(key)) settings.remove(key);
        }
      }
      // So do the host keys it trusts that this device has not confirmed: each
      // is asked about at its first connect unless they were ticked (found in
      // a security review). What it holds of
      // the hosts this device knows changes nothing here either way.
      if (!takeHostKeys) data.remove('known_hosts');

      // Restore data: it adds and writes over, and deletes nothing here.
      final result = await _syncDataService.restoreAll(SyncDataService.withoutStoreCount(data), asBackup: true);

      if (result.success) {
        AppLogger.info(
          'Backup imported: ${result.recordsRestored} records',
        );
        return BackupResult(
          success: true,
          recordCount: result.recordsRestored,
          legacyUnencrypted: isLegacyUnencrypted,
        );
      } else {
        // What the restore said (English, or what it caught) is for the
        // report.
        return BackupResult(
          success: false,
          error: gl10n.backupSvcCouldNotRestore,
          detail: result.error,
          recordCount: result.recordsRestored,
        );
      }
    } catch (e) {
      AppLogger.error('Backup import failed', e);
      return BackupResult(success: false, error: gl10n.backupSvcCouldNotRead, detail: '$e');
    }
  }

  /// Try to derive+decrypt [encrypted] (salt is its first 32 bytes) against
  /// each Argon2id param set in [paramCandidates] in order, answering with
  /// the first that opens it, or with why none did (3.4.2: every failure was
  /// a wrong password). `null` in the list means "current default". [about]
  /// names the file for the details.
  Future<({Map<String, dynamic>? data, BackupResult? refused})> _decryptWithFallback(
    Uint8List encrypted,
    String password,
    List<Map<String, dynamic>?> paramCandidates, {
    required String about,
  }) async {
    final salt = Uint8List.sublistView(encrypted, 0, 32);
    Object? tooLarge;
    Object? unreadable;
    Object? sealed;
    final refusedSettings = <Object>[];
    for (final params in paramCandidates) {
      final SecretKey mek;
      try {
        mek = await SyncService.deriveKey(password, salt, params: params);
      } catch (e) {
        // Settings no ZestSSH backup is made with (weaker than the least, or
        // past the most): the header was changed or damaged.
        refusedSettings.add(e);
        continue;
      }
      try {
        return (data: await SyncService.decrypt(encrypted, mek), refused: null);
      } on SyncDecryptionException catch (e) {
        if (e.message == gl10n.syncDataTooLargeToOpen) {
          tooLarge = e;
        } else if (e.message == gl10n.syncDataDamaged) {
          // It opened: what it holds could not be unpacked or read.
          unreadable = e;
        } else {
          sealed = e;
        }
      } catch (e) {
        sealed = e;
      }
    }
    String said(Object e) => e is SyncException ? (e.detail ?? e.message) : errorKind(e);
    if (tooLarge != null) {
      return (
        data: null,
        refused: BackupResult(
            success: false, error: gl10n.backupOpenTooLarge, detail: 'Backup $about: ${said(tooLarge)}'),
      );
    }
    if (unreadable != null) {
      return (
        data: null,
        refused: BackupResult(
            success: false, error: gl10n.backupSvcCouldNotRead, detail: 'Backup $about: ${said(unreadable)}'),
      );
    }
    if (sealed == null && refusedSettings.isNotEmpty) {
      return (
        data: null,
        refused: BackupResult(
            success: false,
            error: gl10n.backupOpenBadHeader,
            detail: 'Backup $about: key derivation settings refused (${refusedSettings.map(errorKind).join(', ')}: '
                '${refusedSettings.map((e) => e is FormatException ? e.message : '$e').join('; ')})'),
      );
    }
    // The encryption's check failed: the password is wrong, or the file was
    // changed or damaged since it was made. AES-GCM cannot tell which.
    return (
      data: null,
      refused: BackupResult(
        success: false,
        error: gl10n.backupOpenWrongOrDamaged,
        passwordWrong: true,
        detail: 'Backup $about: the encryption check failed (wrong password, or the file was damaged or cut short '
            'after its header)',
      ),
    );
  }

  /// The key derivation settings a version 3 backup's header holds, or null
  /// where it holds none that can be read.
  static Map<String, dynamic>? _header(List<int> bytes) {
    final headerLen = (bytes[5] << 8) | bytes[6];
    try {
      final params = jsonDecode(utf8.decode(bytes.sublist(7, 7 + headerLen)));
      return params is Map<String, dynamic> ? params : null;
    } catch (_) {
      return null;
    }
  }

  /// [params] as the details say them (they are no secret).
  static String _paramsText(Map<String, dynamic> params) =>
      'Argon2id memory ${params['memory']} KiB, ${params['iterations']} iterations, '
      'parallelism ${params['parallelism']}';

  /// Why the backup [bytes] cannot be opened whatever the password, as the
  /// person is told it, with what was found for the details; null where it
  /// may open (3.4.2). In order: not a ZestSSH backup, one a newer version
  /// writes, cut short before a whole backup could fit, a header that is
  /// damaged or holds no settings to open it with.
  static ({String said, String detail})? kindOf(List<int> bytes) {
    const magic = [0x5a, 0x45, 0x53, 0x54]; // ZEST
    final n = bytes.length;
    // Shorter than its own beginning: cut short where what there is begins
    // as a backup does (an empty file included), else something else.
    if (n < 5) {
      final begins = [for (var i = 0; i < n && i < 4; i++) bytes[i] == magic[i]].every((b) => b);
      return begins
          ? (said: gl10n.backupOpenCutShort, detail: 'The file is $n bytes: it ends inside the 5 a backup begins with.')
          : (said: gl10n.backupOpenNotABackup, detail: 'The file ($n bytes) does not begin with "ZEST".');
    }
    if (!isBackupFile(bytes)) {
      return (
        said: gl10n.backupOpenNotABackup,
        detail: bytes[0] == magic[0] && bytes[1] == magic[1] && bytes[2] == magic[2] && bytes[3] == magic[3]
            ? 'The file ($n bytes) begins with "ZEST" and then a byte ${bytes[4]}, which is no backup version.'
            : 'The file ($n bytes) does not begin with "ZEST".',
      );
    }
    final version = bytes[4];
    if (version > 3) {
      return (
        said: gl10n.backupOpenNewer,
        detail: 'Backup version $version, $n bytes; this version of ZestSSH opens versions 1 to 3.',
      );
    }
    if (version == 1 && n < 5 + leastSealed) {
      return (
        said: gl10n.backupOpenCutShort,
        detail: 'Backup version 1, $n bytes: a whole one is at least ${5 + leastSealed}.',
      );
    }
    if (version != 3) return null;
    if (n < 7) {
      return (said: gl10n.backupOpenCutShort, detail: 'Backup version 3, $n bytes: it ends inside its header\'s length.');
    }
    final headerLen = (bytes[5] << 8) | bytes[6];
    // The header is a small JSON object: one larger is damaged, or not ours.
    if (headerLen > 1024) {
      return (
        said: gl10n.backupOpenBadHeader,
        detail: 'Backup version 3, $n bytes: its header says it is $headerLen bytes, more than any backup writes (1024).',
      );
    }
    if (n < 7 + headerLen) {
      return (
        said: gl10n.backupOpenCutShort,
        detail: 'Backup version 3, $n bytes: it ends inside its header of $headerLen bytes.',
      );
    }
    final params = _header(bytes);
    if (params == null) {
      return (
        said: gl10n.backupOpenBadHeader,
        detail: 'Backup version 3, $n bytes: its header of $headerLen bytes is not the key derivation settings.',
      );
    }
    if (n < 7 + headerLen + leastSealed) {
      return (
        said: gl10n.backupOpenCutShort,
        detail: 'Backup version 3, $n bytes: a whole one with this header is at least ${7 + headerLen + leastSealed}.',
      );
    }
    return null;
  }

  /// Count total records in a data map.
  int _countRecords(Map<String, dynamic> data) {
    int count = 0;
    for (final key in [
      'connections',
      'identities',
      'connection_groups',
      'known_hosts',
      'snippets',
      'port_forward_rules',
      'networks',
      'host_network_overrides',
      'port_forward_network_overrides',
    ]) {
      if (data[key] is List) count += (data[key] as List).length;
    }
    return count;
  }
}
