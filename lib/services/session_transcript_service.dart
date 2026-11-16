import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:path/path.dart' as p;
import 'package:zestssh/services/profiles/keychain.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/profiles/profile_move.dart' show freeNameIn;

/// Service for recording and exporting terminal session transcripts.
///
/// Transcripts are stored as timestamped entries and can be exported
/// as plain text. Saved files are **encrypted at rest** with an
/// authenticated stream cipher - an HMAC-SHA256 counter-mode keystream
/// (CTR-style) XORed with the plaintext, then encrypt-then-MAC with
/// HMAC-SHA256 (verified with a constant-time compare before decrypt).
/// The keystream PRF and the MAC use INDEPENDENT HKDF-derived subkeys so
/// they never share a key or input domain (a 1-byte format version lets
/// legacy single-key files still decrypt). It is NOT AES; the 256-bit
/// master key lives in secure storage, so transcript files are unreadable
/// without the device's key.
class SessionTranscriptService {
  static final Map<String, _TranscriptRecorder> _recorders = {};

  /// Secure storage for the transcript encryption key.
  /// Security: options MUST match the database's secure storage to use
  /// the same backing store on all platforms.
  static FlutterSecureStorage get _secureStorage => appKeychain;

  static const _transcriptKeyId = 'zestssh_transcript_encryption_key';

  /// What is being recorded is forgotten: its sessions ended with the profile
  /// they belong to.
  static void forgetAll() {
    for (final r in _recorders.values) {
      r.checkpointTimer?.cancel();
    }
    _recorders.clear();
  }

  /// How often a recording that has new output is written to disk while it
  /// runs (see [checkpoint]).
  @visibleForTesting
  static Duration checkpointEvery = const Duration(seconds: 30);

  /// Where a running recording is written (the transcripts folder); for tests.
  @visibleForTesting
  static Future<Directory> Function() checkpointFolder = _defaultTranscriptsDir;

  /// The name a running recording's file starts with, before its usual name:
  /// it shows in Transcripts as one that was not finished.
  static const checkpointPrefix = 'unfinished_';

  /// Start recording a session.
  static void startRecording(String sessionId, String connectionLabel) {
    if (_recorders.containsKey(sessionId)) return;
    final recorder = _TranscriptRecorder(
      sessionId: sessionId,
      connectionLabel: connectionLabel,
      startedAt: DateTime.now(),
    );
    _recorders[sessionId] = recorder;
    AppLogger.info('Started recording transcript for $sessionId');
  }

  /// Writes what [sessionId]'s recording holds so far to its file in the
  /// transcripts folder ([checkpointPrefix] and its usual name; encrypted as
  /// a saved recording is), when there is anything new since the last time.
  /// Done [checkpointEvery] after new output while it runs. A recording lived in memory
  /// until it was saved, so an app that was killed (a phone short of memory,
  /// a crash, the battery) lost all of it (found in a code audit). The
  /// file goes once the recording is saved and stopped; it stays when the
  /// save at its end failed, or when the app never got there. Never throws.
  static Future<String?> checkpoint(String sessionId) async {
    final recorder = _recorders[sessionId];
    if (recorder == null || !recorder.newSinceCheckpoint || recorder.checkpointing) return null;
    recorder.checkpointing = true;
    try {
      final encrypt = !kDebugMode;
      recorder.checkpointPath ??= '${(await checkpointFolder()).path}/'
          '$checkpointPrefix${suggestedFileNameFor(recorder.connectionLabel, encrypt: encrypt)}';
      recorder.newSinceCheckpoint = false;
      await _writeText(recorder.toPlainText(), recorder.checkpointPath!, encrypt: encrypt);
      return recorder.checkpointPath;
    } catch (e) {
      recorder.newSinceCheckpoint = true;
      AppLogger.warning('A running recording could not be written to disk ($e)');
      return null;
    } finally {
      recorder.checkpointing = false;
    }
  }

  /// Stop recording a session. Its file written while it ran ([checkpoint])
  /// goes when the recording was saved after its last output; otherwise it
  /// stays, as the only copy.
  static _TranscriptRecorder? stopRecording(String sessionId) {
    final recorder = _recorders.remove(sessionId);
    if (recorder != null) {
      recorder.checkpointTimer?.cancel();
      final path = recorder.checkpointPath;
      if (path != null && recorder.savedSinceOutput) {
        try {
          final file = File(path);
          if (file.existsSync()) file.deleteSync();
        } catch (e) {
          AppLogger.warning('The running copy of a saved recording could not be removed ($e)');
        }
      }
      AppLogger.info(
        'Stopped recording $sessionId (${recorder.entries.length} entries)',
      );
    }
    return recorder;
  }

  /// Append data to a recording. The recording is written to disk
  /// [checkpointEvery] after the first output that is not on disk yet.
  static void appendOutput(String sessionId, String data) {
    final recorder = _recorders[sessionId];
    if (recorder == null) return;
    recorder.addEntry(data);
    if (recorder.checkpointTimer?.isActive != true) {
      recorder.checkpointTimer = Timer(checkpointEvery, () => unawaited(checkpoint(sessionId)));
    }
  }

  /// Check if a session is being recorded.
  static bool isRecording(String sessionId) =>
      _recorders.containsKey(sessionId);

  /// The connection label the active recording of [sessionId] was started
  /// with (it names the file), or null when nothing is recording.
  static String? recordingLabel(String sessionId) =>
      _recorders[sessionId]?.connectionLabel;

  /// Export transcript as plain text (in-memory, not encrypted).
  static String exportAsText(String sessionId) {
    final recorder = _recorders[sessionId];
    if (recorder == null) return '';
    return recorder.toPlainText();
  }

  /// Save transcript to an encrypted file and return the path.
  ///
  /// The file is encrypted with an HMAC-SHA256 keystream (CTR-style XOR)
  /// + encrypt-then-MAC HMAC-SHA256. In debug mode, files are saved as
  /// plain text for easier debugging.
  static Future<String?> saveToFile(String sessionId) async {
    lastSaveError = null;
    final recorder = _recorders[sessionId];
    if (recorder == null) {
      lastSaveError = StateError('No recording for this session');
      return null;
    }

    try {
      // Auto-save keeps its historical behaviour: encrypted in release, plain
      // text in debug. The user-facing "Save transcript" flow on desktop asks
      // the user to choose and passes an explicit `encrypt` to saveToPath.
      final encrypt = !kDebugMode;
      final transcriptsDir = await _defaultTranscriptsDir();
      final fullPath =
          '${transcriptsDir.path}/${suggestedFileName(sessionId, encrypt: encrypt)}';
      return await saveToPath(sessionId, fullPath, encrypt: encrypt);
    } catch (e) {
      AppLogger.error('Failed to save transcript', e);
      lastSaveError = e;
      return null;
    }
  }

  /// What stopped the last save that returned null (null after one that
  /// worked), for the report of the notice that says it was not saved: the
  /// saves answer with a path or null, and the reason was only logged.
  static Object? lastSaveError;

  /// Save [sessionId]'s transcript to an explicit [filePath] - e.g. a
  /// location the user just chose in an OS "Save As" dialog. When [encrypt] is
  /// true the file is AES encrypted at rest (`.zesttx`, unreadable outside the
  /// app); when false it is written as plain UTF-8 text (`.txt`, readable in
  /// any editor but NOT protected, so it may expose passwords/keys the session
  /// printed). Any missing parent directories are created. Returns the written
  /// path on success, or null if the session is unknown or the write failed.
  static Future<String?> saveToPath(String sessionId, String filePath,
      {required bool encrypt}) async {
    final recorder = _recorders[sessionId];
    if (recorder == null) {
      lastSaveError = StateError('No recording for this session');
      return null;
    }
    final saved = await saveTextToPath(recorder.toPlainText(), filePath, encrypt: encrypt);
    if (saved != null) recorder.savedSinceOutput = true;
    return saved;
  }

  /// Everything the terminal holds right now (scrollback and screen), framed
  /// like a recording so a saved snapshot and a saved recording read the
  /// same: what it is, which connection, when, and the same warning about
  /// secrets the session may have printed.
  static String bufferAsTranscript(dynamic terminal,
      {required String connectionLabel}) {
    final text = getBufferText(terminal);
    final buffer = StringBuffer();
    buffer.writeln('ZestSSH Session Transcript (snapshot of the terminal)');
    buffer.writeln('Connection: $connectionLabel');
    buffer.writeln('Saved: ${DateTime.now().toIso8601String()}');
    buffer.writeln();
    buffer.writeln(_TranscriptRecorder.securityWarning);
    buffer.writeln('=' * 72);
    buffer.writeln();
    buffer.write(text);
    return buffer.toString();
  }

  /// What [terminal] holds now, saved as a recording is: framed by
  /// [bufferAsTranscript], encrypted, in the transcripts folder (or
  /// [folder]) where the Transcripts page lists it. The written path, or
  /// null when the write failed ([lastSaveError] says why). A phone's Export
  /// transcript with no recording running.
  static Future<String?> saveSnapshot(dynamic terminal,
      {required String connectionLabel, String? folder}) async {
    final transcript = bufferAsTranscript(terminal, connectionLabel: connectionLabel);
    final dir = folder ?? await defaultTranscriptsDirPath();
    final name = suggestedFileNameFor(connectionLabel, encrypt: true);
    return saveTextToPath(transcript, '$dir/$name', encrypt: true);
  }

  /// Write [plainText] to [filePath], encrypted at rest when [encrypt] (see
  /// [saveToPath]) or as plain UTF-8. Missing parent directories are created.
  /// Returns the written path, or null when the write failed.
  static Future<String?> saveTextToPath(String plainText, String filePath,
      {required bool encrypt}) async {
    lastSaveError = null;
    try {
      await _writeText(plainText, filePath, encrypt: encrypt);
      AppLogger.info('Transcript saved (${encrypt ? 'encrypted' : 'plain text'}) to $filePath');
      return filePath;
    } catch (e) {
      AppLogger.error('Failed to save transcript', e);
      lastSaveError = e;
      return null;
    }
  }

  /// Writes [plainText] to [filePath] whole, encrypted when [encrypt]: beside
  /// the name first, then in its place. Throws when it could not.
  static Future<void> _writeText(String plainText, String filePath, {required bool encrypt}) async {
    try {
      final file = File(filePath);
      final parent = file.parent;
      if (!parent.existsSync()) {
        parent.createSync(recursive: true);
      }

      // Written whole beside the name and then put in its place: written
      // straight onto the name, a save stopped in the middle left a cut
      // file there (an encrypted one whose check then failed, read as
      // damaged), over the one before (found in a code audit).
      final part = File('${file.path}.part');
      if (!encrypt) {
        await part.writeAsString(plainText, flush: true);
      } else {
        final key = await _getOrCreateTranscriptKey();
        await part.writeAsBytes(_encrypt(utf8.encode(plainText), key), flush: true);
      }
      await part.rename(file.path);
    } catch (_) {
      try {
        final part = File('$filePath.part');
        if (part.existsSync()) part.deleteSync();
      } catch (_) {}
      rethrow;
    }
  }

  /// Where transcripts go under the app documents folder unless the user
  /// picks another place (a wipe of local data deletes this folder).
  static const String defaultSubdir = 'ZestSSH/transcripts';

  /// The directory transcripts land in when the user does not choose their
  /// own location: `{app documents}/ZestSSH/transcripts`. Created if absent.
  static Future<Directory> _defaultTranscriptsDir() async {
    final dir = await getApplicationDocumentsDirectory();
    // A folder of each profile's own on a computer.
    final transcriptsDir = ProfilePaths.forCurrent(Directory('${dir.path}/$defaultSubdir'));
    if (!transcriptsDir.existsSync()) {
      transcriptsDir.createSync(recursive: true);
    }
    return transcriptsDir;
  }

  /// Public path to the default transcripts directory (created if absent).
  /// Useful as the initial directory for a "Save As" dialog so the picker
  /// opens somewhere sensible.
  static Future<String> defaultTranscriptsDirPath() async =>
      (await _defaultTranscriptsDir()).path;

  /// The recordings in [from], another profile's, come to [to] in the one open now: its
  /// key goes along where this one has none yet, and otherwise each encrypted file is
  /// opened with that key and encrypted with this one's. One that does not open with
  /// it was made elsewhere, and moves as it is. How many could not be moved, and stay.
  static Future<int> bringIn({
    required Directory from,
    required Directory to,
    required FlutterSecureStorage fromKeychain,
    required AppDatabase fromTree,
    required FlutterSecureStorage toKeychain,
    required AppDatabase toTree,
  }) async {
    if (!await from.exists()) return 0;
    final found = [
      for (final entry in await from.list().toList())
        if (entry is File) entry,
    ];
    if (found.isEmpty) return 0;
    final theirs = await openKept(fromTree, _transcriptKeyId, await fromKeychain.read(key: _transcriptKeyId));
    var mine = await openKept(toTree, _transcriptKeyId, await toKeychain.read(key: _transcriptKeyId));
    if (theirs != null && mine == null) {
      await toKeychain.write(key: _transcriptKeyId, value: await keepSealed(toTree, _transcriptKeyId, theirs));
      mine = theirs;
    }
    await to.create(recursive: true);
    var left = 0;
    for (final file in found) {
      try {
        final path = await freeNameIn(to, p.basename(file.path));
        if (theirs != null && mine != null && theirs != mine && file.path.toLowerCase().endsWith('.zesttx')) {
          final text = _decrypt(await file.readAsBytes(), _hexToBytes(theirs));
          if (text != null) {
            await File(path).writeAsBytes(_encrypt(utf8.encode(text), _hexToBytes(mine)), flush: true);
            await file.delete();
            continue;
          }
        }
        await file.rename(path);
      } on FileSystemException catch (e) {
        left++;
        AppLogger.warning('A recording stayed where it was (${e.osError?.errorCode})');
      }
    }
    return left;
  }

  /// The transcripts in [folder] (the app's own folder when null), newest
  /// first: what a phone's recordings saved, and what a computer saved
  /// there. Nothing listed them, and nothing in the app opened one (3.0, 17
  /// October 2026).
  static Future<List<SavedTranscript>> listSaved({Directory? folder}) async {
    final dir = folder ?? await _defaultTranscriptsDir();
    if (!dir.existsSync()) return const [];
    final found = <SavedTranscript>[];
    await for (final entry in dir.list(followLinks: false)) {
      if (entry is! File) continue;
      final name = p.basename(entry.path);
      if (!isTranscriptName(name)) continue;
      final stat = await entry.stat();
      found.add(SavedTranscript(path: entry.path, name: name, modified: stat.modified, size: stat.size));
    }
    found.sort((a, b) => b.modified.compareTo(a.modified));
    return found;
  }

  /// Whether [name] is a transcript's: one the app encrypted (.zesttx), or
  /// one saved as plain text (.txt).
  static bool isTranscriptName(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.zesttx') || lower.endsWith('.txt');
  }

  /// Why the last [readFromFile] that returned null did not open its file
  /// (null after one that did), in English, for Copy details.
  static Object? lastReadError;

  /// A sensible default file name for [sessionId]'s transcript, with the
  /// extension matching the [encrypt] choice: `.zesttx` when encrypted at rest,
  /// `.txt` when saved as plain text. Falls back to a generic label when the
  /// session is not currently being recorded.
  static String suggestedFileName(String sessionId, {required bool encrypt}) =>
      suggestedFileNameFor(_recorders[sessionId]?.connectionLabel,
          encrypt: encrypt);

  /// [suggestedFileName] for a connection label rather than a recording, so
  /// a snapshot of a session that is not being recorded is named after its
  /// host too. Null falls back to a generic name.
  static String suggestedFileNameFor(String? rawLabel,
      {required bool encrypt}) {
    // Recording mode: this label names the host and becomes the default file
    // name in the save dialog and the name on disk, so mask it BEFORE
    // sanitising. Sanitising first would turn `db-primary.local` into `db-primary_local`,
    // which the free-text scan (guarding the "saved to ..." toast) no longer
    // recognises as an address. The generic no-recorder fallback stays literal.
    final label = rawLabel == null || rawLabel.isEmpty
        ? 'session'
        : Redactable.host(rawLabel).display;
    final sanitizedLabel = label.replaceAll(RegExp(r'[^\w\-.]'), '_');
    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final ext = encrypt ? 'zesttx' : 'txt';
    return '${sanitizedLabel}_$timestamp.$ext';
  }

  /// Read and decrypt a saved transcript file.
  ///
  /// Handles both encrypted (.zesttx) and legacy plain text (.txt) files.
  static Future<String?> readFromFile(String filePath) async {
    lastReadError = null;
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        lastReadError = FileSystemException('No such file', filePath);
        return null;
      }

      if (filePath.toLowerCase().endsWith('.txt')) {
        // Legacy unencrypted file
        return await file.readAsString();
      }

      // Encrypted file. Never MINT a key here - reading requires the key
      // that encrypted the file. A storage-read error rethrows into the
      // outer catch (returns null) rather than silently creating a fresh
      // key that can't decrypt anything.
      final bytes = await file.readAsBytes();
      final key = await _readTranscriptKey();
      if (key == null) {
        AppLogger.error('No transcript key available to decrypt $filePath');
        lastReadError = StateError('This device has no transcript key: it was made on another device, or before this device\'s data was reset');
        return null;
      }
      final text = _decrypt(bytes, key);
      if (text == null) {
        lastReadError = StateError('It does not open with this device\'s transcript key: made on another device, or damaged');
      }
      return text;
    } catch (e) {
      AppLogger.error('Failed to read transcript', e);
      lastReadError = e;
      return null;
    }
  }

  /// Get the full buffer text of a session (whether recording or not).
  static String getBufferText(dynamic terminal) {
    try {
      final buffer = terminal.buffer;
      final out = StringBuffer();
      for (var i = 0; i < buffer.lines.length; i++) {
        final line = buffer.lines[i];
        // Honour isWrapped: a wrapped row is a soft-wrap continuation, not a
        // new logical line - don't insert a newline before it.
        if (i != 0 && line.isWrapped != true) out.write('\n');
        out.write(line.toString());
      }
      return out.toString();
    } catch (e) {
      AppLogger.error('Failed to get terminal buffer text', e);
      return '';
    }
  }

  // ── Encryption helpers ──────────────────────────────────────────

  /// Read the existing transcript key, or null if none has been created yet.
  ///
  /// Deliberately does NOT catch storage-read errors: a transient failure
  /// must rethrow so callers never silently mint a new key and permanently
  /// orphan every previously-saved transcript. Also validates that the
  /// stored value is real 32-byte hex (not merely 64 chars) so a corrupted
  /// entry fails loudly instead of decrypting to garbage.
  ///
  /// Sealed while the encrypting lock is on (SecretSeal): opened with your
  /// Tree's database; while the app is locked a sealed key throws
  /// ([SecretSealBroken]) rather than reading as none, so no new key is made
  /// over it.
  static Future<Uint8List?> _readTranscriptKey() async {
    final hexKey = await openKeptOrThrow(
        SecretSeal.openTree, _transcriptKeyId, await _secureStorage.read(key: _transcriptKeyId));
    if (hexKey == null) return null;
    if (hexKey.length != 64 || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hexKey)) {
      throw StateError('Stored transcript key is malformed');
    }
    return _hexToBytes(hexKey);
  }

  /// Create and persist a fresh transcript key (32 bytes = 256 bits).
  static Future<Uint8List> _createTranscriptKey() async {
    final random = Random.secure();
    final keyBytes = Uint8List.fromList(
      List.generate(32, (_) => random.nextInt(256)),
    );
    final hex =
        keyBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    await _secureStorage.write(
        key: _transcriptKeyId, value: await keepSealed(SecretSeal.openTree, _transcriptKeyId, hex));
    return keyBytes;
  }

  /// Key for WRITING a transcript: reuse the existing key, or create one
  /// ONLY when the read succeeded and genuinely returned null (first save).
  /// A storage-read error propagates and aborts the save instead of minting
  /// a replacement key.
  static Future<Uint8List> _getOrCreateTranscriptKey() async {
    final existing = await _readTranscriptKey();
    return existing ?? await _createTranscriptKey();
  }

  /// Derive a domain-separated 32-byte subkey from the master key via an
  /// HKDF-Expand-style single-block HMAC (RFC 5869, L=32). Gives the
  /// keystream PRF and the MAC independent keys so they can never share
  /// input domains.
  static Uint8List _deriveSubkey(Uint8List key, String info) {
    final h = Hmac(sha256, key);
    final data = <int>[...utf8.encode(info), 0x01];
    return Uint8List.fromList(h.convert(data).bytes);
  }

  /// Domain-separation labels for the v1 (HKDF-split) scheme.
  static const _encInfo = 'zestssh-transcript-enc';
  static const _macInfo = 'zestssh-transcript-mac';

  /// Format version byte for the current (HKDF-split) scheme. Legacy files
  /// have no version prefix; [_decrypt] falls back to the legacy path.
  static const _formatV1 = 0x01;

  /// Encrypt plaintext bytes (current scheme, v1).
  ///
  /// Format: [1-byte version=0x01] [16-byte IV] [ciphertext] [32-byte HMAC]
  ///
  /// The keystream PRF and the MAC use INDEPENDENT, HKDF-derived subkeys
  /// (K_enc / K_mac) so they never share a key or input domain - closing
  /// the short-message tag-forgery gap of the old single-key scheme. Still
  /// a CTR-style HMAC-SHA256 keystream (not AES) with encrypt-then-MAC.
  static Uint8List _encrypt(List<int> plaintext, Uint8List key) {
    final kEnc = _deriveSubkey(key, _encInfo);
    final kMac = _deriveSubkey(key, _macInfo);

    final random = Random.secure();
    final iv = Uint8List.fromList(
      List.generate(16, (_) => random.nextInt(256)),
    );

    final encrypted = _xorStream(Uint8List.fromList(plaintext), kEnc, iv);

    // MAC covers version || IV || ciphertext (binds the format version).
    final macInput = Uint8List(1 + iv.length + encrypted.length);
    macInput[0] = _formatV1;
    macInput.setAll(1, iv);
    macInput.setAll(1 + iv.length, encrypted);
    final mac = Hmac(sha256, kMac).convert(macInput).bytes;

    // [version (1)] [IV (16)] [ciphertext (N)] [HMAC (32)]
    final result = Uint8List(1 + 16 + encrypted.length + 32);
    result[0] = _formatV1;
    result.setAll(1, iv);
    result.setAll(1 + 16, encrypted);
    result.setAll(1 + 16 + encrypted.length, mac);
    return result;
  }

  /// Decrypt ciphertext bytes. Returns null on integrity failure.
  ///
  /// Tries the v1 (version-prefixed, HKDF-split) scheme first; if that
  /// doesn't authenticate, falls back to the legacy single-key scheme so
  /// transcripts saved before the migration stay readable. Both paths are
  /// authenticated, so a wrong-scheme guess simply fails the MAC.
  static String? _decrypt(Uint8List data, Uint8List key) {
    // v1: 1 version + 16 IV + >=0 data + 32 HMAC.
    if (data.isNotEmpty && data[0] == _formatV1 && data.length >= 49) {
      final kEnc = _deriveSubkey(key, _encInfo);
      final kMac = _deriveSubkey(key, _macInfo);
      final iv = data.sublist(1, 17);
      final ciphertext = data.sublist(17, data.length - 32);
      final storedMac = data.sublist(data.length - 32);

      final macInput = data.sublist(0, data.length - 32);
      final computedMac = Hmac(sha256, kMac).convert(macInput).bytes;
      if (_constantTimeEquals(
          Uint8List.fromList(storedMac), Uint8List.fromList(computedMac))) {
        final plaintext = _xorStream(Uint8List.fromList(ciphertext), kEnc, iv);
        return utf8.decode(plaintext, allowMalformed: true);
      }
      // MAC didn't verify under v1 - fall through to try the legacy scheme
      // (a legacy file can coincidentally start with 0x01).
    }

    return _decryptLegacy(data, key);
  }

  /// Legacy decrypt: [16 IV] [ciphertext] [32 HMAC], single key for both the
  /// keystream and the MAC. Kept only to read pre-migration transcripts.
  static String? _decryptLegacy(Uint8List data, Uint8List key) {
    if (data.length < 48) return null; // 16 IV + 0 data + 32 HMAC minimum

    final iv = data.sublist(0, 16);
    final ciphertext = data.sublist(16, data.length - 32);
    final storedMac = data.sublist(data.length - 32);

    final macInput = Uint8List(iv.length + ciphertext.length);
    macInput.setAll(0, iv);
    macInput.setAll(iv.length, ciphertext);
    final computedMac = Hmac(sha256, key).convert(macInput).bytes;

    if (!_constantTimeEquals(
        Uint8List.fromList(storedMac), Uint8List.fromList(computedMac))) {
      AppLogger.error('Transcript decryption failed: HMAC mismatch');
      return null;
    }

    final plaintext =
        _xorStream(Uint8List.fromList(ciphertext), key, Uint8List.fromList(iv));
    return utf8.decode(plaintext, allowMalformed: true);
  }

  /// XOR-based stream cipher using HMAC-SHA256 as the keystream generator.
  ///
  /// For each 32-byte block, generates keystream = HMAC(key, IV || counter).
  /// This is effectively CTR mode with HMAC-SHA256 as the block cipher.
  static Uint8List _xorStream(Uint8List data, Uint8List key, Uint8List iv) {
    final result = Uint8List(data.length);
    final hmacKey = Hmac(sha256, key);
    var offset = 0;
    var counter = 0;

    while (offset < data.length) {
      // Build counter block: IV + 4-byte big-endian counter
      final counterBlock = Uint8List(iv.length + 4);
      counterBlock.setAll(0, iv);
      counterBlock[iv.length] = (counter >> 24) & 0xFF;
      counterBlock[iv.length + 1] = (counter >> 16) & 0xFF;
      counterBlock[iv.length + 2] = (counter >> 8) & 0xFF;
      counterBlock[iv.length + 3] = counter & 0xFF;

      final keystream = hmacKey.convert(counterBlock).bytes;
      for (var i = 0; i < 32 && offset < data.length; i++, offset++) {
        result[offset] = data[offset] ^ keystream[i];
      }
      counter++;
    }
    return result;
  }

  /// Constant-time byte array comparison.
  static bool _constantTimeEquals(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var result = 0;
    for (var i = 0; i < a.length; i++) {
      result |= a[i] ^ b[i];
    }
    return result == 0;
  }

  static Uint8List _hexToBytes(String hex) {
    final bytes = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }
}

/// A transcript saved on this device.
class SavedTranscript {
  const SavedTranscript({required this.path, required this.name, required this.modified, required this.size});

  final String path;
  final String name;
  final DateTime modified;
  final int size;

  /// Encrypted with this device's key (it opens on this device alone).
  bool get encrypted => name.toLowerCase().endsWith('.zesttx');
}

class _TranscriptRecorder {
  static const _maxEntries = 50000;

  /// The header every saved transcript carries, recording or snapshot.
  static const securityWarning = 'SECURITY WARNING: This transcript may '
      'contain passwords, API keys, tokens, and other sensitive data typed '
      'at interactive prompts (e.g. sudo, mysql, ssh). Review carefully '
      'before sharing.';

  /// Hard cap on total buffered transcript bytes, independent of entry
  /// count - a single command that streams megabytes (e.g. `cat` on a big
  /// file) could otherwise blow memory well before hitting [_maxEntries].
  static const _maxBytes = 16 * 1024 * 1024; // 16 MB

  /// The line a saved recording carries when its start was left out.
  static String droppedNote(int chars) =>
      'NOTE: The first $chars characters of output were left out. A recording keeps at most '
      '${_maxBytes ~/ (1024 * 1024)} MB and $_maxEntries pieces of output, the newest.';

  final String sessionId;
  final String connectionLabel;
  final DateTime startedAt;

  /// ListQueue so front-eviction is O(1) instead of List.removeAt(0)'s O(n).
  final ListQueue<_TranscriptEntry> entries = ListQueue();

  int _byteTotal = 0;

  /// The recording's file written while it runs (SessionTranscriptService
  /// .checkpoint), once there is one.
  String? checkpointPath;
  Timer? checkpointTimer;
  bool checkpointing = false;

  /// Output came since the last checkpoint.
  bool newSinceCheckpoint = false;

  /// A save went through after the last output.
  bool savedSinceOutput = false;

  /// Output left out from the start to keep within the caps: how much, in
  /// characters. Said at the top of the saved text: the file began in the
  /// middle with nothing to say so (found in a code audit).
  int _droppedChars = 0;

  _TranscriptRecorder({
    required this.sessionId,
    required this.connectionLabel,
    required this.startedAt,
  });

  void addEntry(String data) {
    newSinceCheckpoint = true;
    savedSinceOutput = false;
    final bytes = data.length;
    entries.add(_TranscriptEntry(
      timestamp: DateTime.now().difference(startedAt),
      data: data,
    ));
    _byteTotal += bytes;

    // Evict oldest entries until BOTH the count and byte budgets hold.
    while (entries.length > _maxEntries ||
        (_byteTotal > _maxBytes && entries.length > 1)) {
      final removed = entries.removeFirst();
      _byteTotal -= removed.data.length;
      _droppedChars += removed.data.length;
    }
  }

  String toPlainText() {
    final buffer = StringBuffer();
    buffer.writeln('ZestSSH Session Transcript');
    buffer.writeln('Connection: $connectionLabel');
    buffer.writeln('Session ID: $sessionId');
    buffer.writeln('Started: ${startedAt.toIso8601String()}');
    buffer.writeln(
      'Duration: ${entries.isEmpty ? '0s' : entries.last.timestamp.toString().split('.').first}',
    );
    buffer.writeln();
    buffer.writeln(securityWarning);
    if (_droppedChars > 0) {
      buffer.writeln();
      buffer.writeln(droppedNote(_droppedChars));
    }
    buffer.writeln('=' * 72);
    buffer.writeln();
    for (final entry in entries) {
      buffer.write(entry.data);
    }
    return buffer.toString();
  }
}

class _TranscriptEntry {
  final Duration timestamp;
  final String data;

  const _TranscriptEntry({required this.timestamp, required this.data});
}
