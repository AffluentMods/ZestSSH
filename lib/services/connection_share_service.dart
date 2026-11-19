import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute, visibleForTesting;
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:share_plus/share_plus.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/connection_share_url_service.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';

/// Service for exporting and importing connection configs as `.zest` files.
///
/// Plain exports contain only non-sensitive metadata (host, port, protocol,
/// color index, port forward rules, etc.).
///
/// When the user opts to include credentials (password / private key),
/// the `.zest` file is AES-256-GCM encrypted with a user-chosen password
/// using PBKDF2 key derivation - consistent with the app's other crypto.
class ConnectionShareService {
  /// The shortest password a share holding a password or a key is sealed
  /// with.
  static const minPasswordLength = 12;

  /// What a shared host file's `type` says: a host shared in the clear, and
  /// one sealed under a password (with its password, its private key or both
  /// inside).
  static const plainType = 'zestssh_connection';
  static const sealedType = 'zestssh_connection_encrypted';

  /// The largest file read as a shared host. One holds a host, its user, its
  /// forwards and at most a password and a private key: a few kilobytes.
  static const maxFileBytes = 1024 * 1024;

  /// The most forwards a shared host may come with: as many as can run at
  /// once.
  static const maxForwards = 50;

  /// The shared host file [bytes] hold, decoded, or null where they are not
  /// one: a backup (a `.zest` file as well), or anything else.
  static Map<String, dynamic>? _shareOf(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > maxFileBytes) return null;
    try {
      final json = jsonDecode(utf8.decode(bytes));
      if (json is! Map<String, dynamic>) return null;
      final type = json['type'];
      return type == plainType || type == sealedType ? json : null;
    } catch (_) {
      return null;
    }
  }

  /// Whether [bytes] are a host shared from ZestSSH (what [exportConnection]
  /// writes), sealed or not.
  static bool isShareFile(List<int> bytes) => _shareOf(bytes) != null;

  /// Whether [bytes] are a shared host sealed under a password, which
  /// [importConnection] needs to read it.
  static bool isSealedShare(List<int> bytes) => _shareOf(bytes)?['type'] == sealedType;

  /// [name] as a name may be kept and shown: without control characters, nor
  /// those that make text read other than it is (refused in a share link,
  /// [ConnectionShareUrlService.isSpoofingControl]), no longer than a saved
  /// name may be. Null where nothing is left.
  static String? _nameOf(Object? name) {
    if (name is! String) return null;
    final kept = StringBuffer();
    var units = 0;
    for (final rune in name.runes) {
      if (rune <= 0x1f || (rune >= 0x7f && rune <= 0x9f) || ConnectionShareUrlService.isSpoofingControl(rune)) continue;
      final width = rune > 0xffff ? 2 : 1;
      if (units + width > 255) break;
      kept.writeCharCode(rune);
      units += width;
    }
    final said = kept.toString().trim();
    return said.isEmpty ? null : said;
  }

  /// Whether [value] may be an address or a user as it is: not empty (unless
  /// [mayBeEmpty]), no longer than [max], with no control characters, nor any
  /// that make it read other than it is.
  static bool _plain(String value, int max, {bool mayBeEmpty = false}) =>
      (mayBeEmpty || value.isNotEmpty) &&
      value.length <= max &&
      !value.contains(RegExp(r'[\x00-\x1f\x7f-\x9f]')) &&
      !ConnectionShareUrlService.hasSpoofingControl(value);

  /// Export a connection to a `.zest` file.
  ///
  /// Returns the path to the generated temp file.
  static Future<String> exportConnection({
    required Connection connection,
    required Identity? identity,
    required List<PortForwardRule> portForwardRules,
    String? password,
    String? privateKeyPem,
    String? encryptionPassword,
  }) async {
    final data = <String, dynamic>{
      'version': 1,
      'type': plainType,
      'connection': {
        'label': connection.label,
        'host': connection.host,
        'port': connection.port,
        'protocol': connection.protocol,
        'colorIndex': connection.colorIndex,
        'zlibCompression': connection.zlibCompression,
        'keepAliveSeconds': connection.keepAliveSeconds,
      },
    };

    // Include identity metadata (without secrets unless requested)
    if (identity != null) {
      data['identity'] = {
        'label': identity.label,
        'username': identity.username,
        'authMethod': identity.authMethod,
        'keyType': identity.keyType,
        'colorIndex': identity.colorIndex,
      };
    }

    // Include port forward rules
    if (portForwardRules.isNotEmpty) {
      data['portForwards'] = portForwardRules
          .map((r) => {
                'type': r.type,
                'bindAddress': r.bindAddress,
                'bindPort': r.bindPort,
                'remoteHost': r.remoteHost,
                'remotePort': r.remotePort,
                'autoStart': r.autoStart,
                'label': r.label,
              })
          .toList();
    }

    // Include sensitive data if requested
    final hasSensitiveData = password != null || privateKeyPem != null;
    if (hasSensitiveData) {
      data['secrets'] = <String, dynamic>{};
      if (password != null) {
        data['secrets']['password'] = password;
      }
      if (privateKeyPem != null) {
        data['secrets']['privateKey'] = privateKeyPem;
      }
    }

    // Enforce minimum encryption password when secrets are present (the
    // share dialog says so first; this is the backstop).
    if (hasSensitiveData &&
        encryptionPassword != null &&
        encryptionPassword.length < minPasswordLength) {
      throw ArgumentError(
          'Encryption password must be at least 12 characters when '
          'exporting credentials.');
    }

    String jsonContent;
    if (hasSensitiveData && encryptionPassword != null) {
      // Encrypt the entire JSON with AES-256-GCM
      final plaintext = jsonEncode(data);
      // In a worker: the password is stretched 600,000 times, which held the
      // screen still for more than a second on a computer and for seconds on
      // a phone (found in a code audit); the import already ran in one.
      final encrypted = await compute(_encryptIn, (plaintext, encryptionPassword));
      jsonContent = jsonEncode({
        'version': 1,
        'type': sealedType,
        'data': encrypted,
      });
    } else {
      // Remove secrets if no encryption password provided
      if (hasSensitiveData && encryptionPassword == null) {
        data.remove('secrets');
      }
      jsonContent = jsonEncode(data);
    }

    // Write it into a folder of its own in the app's temporary folder, which
    // [removeShareFile] deletes once it has been shared. (3.0: it
    // was written straight into the temporary folder and never deleted, so
    // the host, the user and the forwards stayed there in the clear, with
    // the password and the key if chosen, sealed under a password that can
    // be guessed offline.)
    final folder = await newShareFolder();
    final safeName =
        connection.label.replaceAll(RegExp(r'[^\w\-.]'), '_').toLowerCase();
    final file = File('${folder.path}${Platform.pathSeparator}$safeName.zest');
    await file.writeAsString(jsonContent);

    return file.path;
  }

  /// What the folders a share is written into start with.
  static const shareFolderPrefix = 'zestssh_share_';

  /// The kinds of host a share carries: a `.zest` host file of any other is
  /// refused on import, and a link or QR code carries no kind at all, so what
  /// it adds is an SSH host at that address.
  static const shareableProtocols = {'ssh', 'sftp', 'telnet', 'mosh', 'et'};

  /// Whether a host saved with [protocol] can be shared (as a file, a link or
  /// a QR code): only then is what the other person receives the same host.
  /// A remote screen, an FTPS host, a serial or a local one is not offered.
  static bool canShare(String? protocol) => shareableProtocols.contains(protocol ?? 'ssh');

  /// A new folder, of its own, in the app's folder of temporary files, for
  /// what is handed to the share sheet; only the person can open it (the
  /// system makes it so). [removeAfterShare] deletes it once the sheet has
  /// closed, and [removeLeftovers] what a crash left.
  static Future<Directory> newShareFolder() async =>
      Directory((await getTemporaryDirectory()).path).createTemp(shareFolderPrefix);

  /// Hands [files] (each a name and what it holds) to the share sheet: they
  /// are written into a folder of their own ([newShareFolder]), [written] is
  /// called (to say so before the sheet opens, where it is seen even when the
  /// sheet is dismissed at once), and the folder is deleted once the sheet has
  /// closed, or once writing them or opening the sheet failed. Throws what
  /// that threw.
  static Future<void> shareFiles(
    Map<String, List<int>> files, {
    String? subject,
    String? text,
    void Function()? written,
  }) async {
    assert(files.isNotEmpty);
    final folder = await newShareFolder();
    final made = '${folder.path}${Platform.pathSeparator}';
    try {
      for (final MapEntry(key: name, value: bytes) in files.entries) {
        await File('$made$name').writeAsBytes(bytes, flush: true);
      }
      written?.call();
      await Share.shareXFiles([for (final name in files.keys) XFile('$made$name')], subject: subject, text: text);
    } finally {
      // Once the sheet has closed, as every share is ([removeAfterShare]).
      await _delete(folder);
    }
  }

  /// What is done with a shared file once the share sheet has closed: it is
  /// deleted, with the folder made for it ([removeShareFile]). The app chosen
  /// has what it needs by then: on an iPhone it has taken the file, and on
  /// Android the sheet was handed a copy of its own (share_plus copies the
  /// file into the app's cache folder, `share_plus/`, before the sheet
  /// opens), which share_plus deletes at the next share and
  /// [removeLeftovers] once it is an hour old. (It was left on Android, for
  /// the next start, as if the app chosen read it from where it was written.)
  static Future<void> removeAfterShare(String path) => removeShareFile(path);

  /// Deletes a shared file ([path], as [exportConnection] or [shareFiles]
  /// write it) and the folder made for it, once it has been shared. Never
  /// throws.
  static Future<void> removeShareFile(String path) async {
    final folder = File(path).parent;
    final ownFolder = folder.uri.pathSegments.where((s) => s.isNotEmpty).last.startsWith(shareFolderPrefix);
    await _delete(ownFolder ? folder : File(path));
  }

  /// Deletes [shared], a shared file or the folder made for it. Never throws.
  static Future<void> _delete(FileSystemEntity shared) async {
    try {
      await shared.delete(recursive: true);
    } catch (e) {
      AppLogger.warning('A shared file was not deleted (${errorKind(e)})');
    }
  }

  /// Deletes what shares left in the app's folder of temporary files
  /// [tempPath]: the folders made for them that a crash left, and what
  /// earlier versions left there: the `.zest` files of shared hosts, written
  /// straight into it, and the folders `zest_share_...` a file shared from a
  /// host's file pane was fetched into. On a phone, where that folder is the
  /// app's own, also the files earlier versions handed to the share sheet
  /// straight from it and never deleted ([_handedOverBefore]: an exported
  /// private key, the snippets, a theme); and on Android the copies the
  /// share sheet was handed (`share_plus/`, see [removeAfterShare]), once
  /// nothing has been shared for an hour. Run once at start-up. Never throws.
  /// [phone], [android] and [now] are for tests.
  static Future<void> removeLeftovers(
    String tempPath, {
    @visibleForTesting bool? phone,
    @visibleForTesting bool? android,
    @visibleForTesting DateTime? now,
  }) async {
    final onPhone = phone ?? (Platform.isAndroid || Platform.isIOS);
    final onAndroid = android ?? Platform.isAndroid;
    var left = 0;
    try {
      final temp = Directory(tempPath);
      if (!await temp.exists()) return;
      await for (final entity in temp.list(followLinks: false)) {
        final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
        try {
          if (entity is Directory && (name.startsWith(shareFolderPrefix) || name.startsWith('zest_share_'))) {
            await entity.delete(recursive: true);
          } else if (entity is Directory && name == 'share_plus' && onAndroid) {
            await _removeHandedCopies(entity, (now ?? DateTime.now()).subtract(const Duration(hours: 1)));
          } else if (entity is File && name.toLowerCase().endsWith('.zest')) {
            await entity.delete();
          } else if (entity is File && onPhone && _handedOverBefore.hasMatch(name)) {
            await entity.delete();
          }
        } catch (_) {
          left++;
        }
      }
    } catch (e) {
      AppLogger.warning('The folder of temporary files was not read (${errorKind(e)})');
    }
    if (left > 0) AppLogger.warning('$left files that shares left were not deleted');
  }

  /// The files versions before 3.0 handed to a phone's share sheet straight
  /// from its folder of temporary files, never deleted: an exported private
  /// key and its public key (`<name>_id_rsa.pem`, `<name>_id_rsa.pub`), the
  /// snippets (`zestssh_snippets.json`) and a terminal theme (`<name>.zestheme`).
  static final _handedOverBefore = RegExp(r'(_id_rsa\.(pem|pub)|\.zestheme)$|^zestssh_snippets\.json$');

  /// Deletes the copies in share_plus's folder [folder] made before
  /// [changedBefore], and the folder once it holds nothing.
  static Future<void> _removeHandedCopies(Directory folder, DateTime changedBefore) async {
    await for (final copy in folder.list(followLinks: false)) {
      if (copy is File && (await copy.stat()).modified.isBefore(changedBefore)) await copy.delete();
    }
    if (await folder.list().isEmpty) await folder.delete();
  }

  /// Parse a `.zest` file and return the connection data.
  ///
  /// If the file is encrypted, [decryptionPassword] is required.
  /// Returns `null` if decryption fails.
  static Future<ZestImportData?> importConnection(
    String filePath, {
    String? decryptionPassword,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) return null;
    // Larger than any shared host: not read.
    if (await file.length() > maxFileBytes) {
      throw const FormatException('Too large for a shared host');
    }

    final content = await file.readAsString();
    final json = jsonDecode(content) as Map<String, dynamic>;

    Map<String, dynamic> data;
    if (json['type'] == sealedType) {
      if (decryptionPassword == null) {
        throw const FormatException('File is encrypted - password required');
      }
      final decrypted = _decrypt(
        json['data'] as String,
        decryptionPassword,
      );
      if (decrypted == null) return null;
      data = jsonDecode(decrypted) as Map<String, dynamic>;
    } else {
      data = json;
    }

    final conn = data['connection'] as Map<String, dynamic>;
    final identity = data['identity'] as Map<String, dynamic>?;
    final secrets = data['secrets'] as Map<String, dynamic>?;
    final portForwards = data['portForwards'] as List<dynamic>?;

    // Validate imported fields to prevent malicious .zest files from
    // injecting invalid data into the database. The file comes from someone
    // else: its address and its user are taken as they are or not at all,
    // as a share link's are (3.0: an empty address was taken, and characters
    // that make an address read other than it is), and its names are kept
    // without what a name may not hold.
    final host = conn['host'] as String? ?? '';
    final port = conn['port'] as int? ?? 22;
    final protocol = conn['protocol'] as String? ?? 'ssh';
    final username = identity?['username'] as String?;

    if (!_plain(host, 253)) {
      throw const FormatException('Invalid host in imported connection');
    }
    if (port < 1 || port > 65535) {
      throw FormatException('Invalid port in imported connection: $port');
    }
    if (!shareableProtocols.contains(protocol)) {
      throw FormatException('Invalid protocol in imported connection: $protocol');
    }
    if (username != null && !_plain(username, 255, mayBeEmpty: true)) {
      throw const FormatException('Invalid user in imported connection');
    }
    if (portForwards != null && portForwards.length > maxForwards) {
      throw const FormatException('Too many forwards in imported connection');
    }

    return ZestImportData(
      label: _nameOf(conn['label']) ?? host,
      host: host,
      port: port,
      protocol: protocol,
      colorIndex: conn['colorIndex'] as int? ?? 0,
      zlibCompression: conn['zlibCompression'] as bool? ?? false,
      // A keep-alive of days, or below nothing, is none a person set.
      keepAliveSeconds: min(max(conn['keepAliveSeconds'] as int? ?? 0, 0), 86400),
      identityLabel: _nameOf(identity?['label']),
      username: username == null || username.isEmpty ? null : username,
      authMethod: identity?['authMethod'] as String?,
      keyType: _nameOf(identity?['keyType']),
      identityColorIndex: identity?['colorIndex'] as int? ?? 0,
      password: secrets?['password'] as String?,
      privateKeyPem: secrets?['privateKey'] as String?,
      portForwards: portForwards
              ?.map((pf) {
                final pfType = pf['type'] as String? ?? 'local';
                final pfBindAddr =
                    pf['bindAddress'] as String? ?? '127.0.0.1';
                final pfBindPort = pf['bindPort'] as int? ?? 0;
                final pfRemoteHost =
                    pf['remoteHost'] as String? ?? 'localhost';
                final pfRemotePort = pf['remotePort'] as int? ?? 0;

                // Validate port forward type
                const validPfTypes = {'local', 'remote', 'dynamic'};
                if (!validPfTypes.contains(pfType)) return null;
                // Validate ports
                if (pfBindPort < 0 || pfBindPort > 65535) return null;
                if (pfRemotePort < 0 || pfRemotePort > 65535) return null;
                // Reject overly long addresses, and control characters or
                // any that make one read other than it is
                if (!_plain(pfBindAddr, 253, mayBeEmpty: true) ||
                    !_plain(pfRemoteHost, 253, mayBeEmpty: true)) {
                  return null;
                }

                return ZestPortForward(
                  type: pfType,
                  bindAddress: pfBindAddr,
                  bindPort: pfBindPort,
                  remoteHost: pfRemoteHost,
                  remotePort: pfRemotePort,
                  autoStart: pf['autoStart'] as bool? ?? false,
                  label: _nameOf(pf['label']),
                );
              })
              .whereType<ZestPortForward>()
              .toList() ??
          [],
      isEncrypted: json['type'] == sealedType,
    );
  }

  // ── AES-256-GCM encryption ──────────────────────────────────

  /// [_encrypt] for [compute]: what to seal and its password.
  static String _encryptIn((String, String) what) => _encrypt(what.$1, what.$2);

  static String _encrypt(String plaintext, String password) {
    final salt = _randomBytes(16);
    final key = _deriveKey(password, salt);
    final iv = _randomBytes(12);

    final cipher = pc.GCMBlockCipher(pc.AESEngine())
      ..init(
        true,
        pc.AEADParameters(
          pc.KeyParameter(key),
          128, // tag length bits
          iv,
          Uint8List(0),
        ),
      );

    final plaintextBytes = utf8.encode(plaintext);
    final ciphertext = cipher.process(Uint8List.fromList(plaintextBytes));

    // Encode as base64: salt + iv + ciphertext (includes GCM tag)
    final combined = Uint8List(salt.length + iv.length + ciphertext.length);
    combined.setAll(0, salt);
    combined.setAll(salt.length, iv);
    combined.setAll(salt.length + iv.length, ciphertext);

    return base64Encode(combined);
  }

  static String? _decrypt(String encryptedBase64, String password) {
    // Try current iteration count first, then fall back to legacy (100K)
    // for backwards compatibility with previously exported .zest files.
    final result = _tryDecrypt(encryptedBase64, password, _pbkdf2Iterations);
    if (result != null) return result;
    return _tryDecrypt(encryptedBase64, password, _legacyPbkdf2Iterations);
  }

  static String? _tryDecrypt(
      String encryptedBase64, String password, int iterations) {
    try {
      final combined = base64Decode(encryptedBase64);
      final salt = combined.sublist(0, 16);
      final iv = combined.sublist(16, 28);
      final ciphertext = combined.sublist(28);
      final key = _deriveKeyWithIterations(
          password, Uint8List.fromList(salt), iterations);

      final cipher = pc.GCMBlockCipher(pc.AESEngine())
        ..init(
          false,
          pc.AEADParameters(
            pc.KeyParameter(key),
            128,
            Uint8List.fromList(iv),
            Uint8List(0),
          ),
        );

      final decrypted = cipher.process(Uint8List.fromList(ciphertext));
      return utf8.decode(decrypted);
    } catch (_) {
      return null; // Wrong password, wrong iterations, or corrupt data
    }
  }

  static const _pbkdf2Iterations = 600000;
  static const _legacyPbkdf2Iterations = 100000;

  static Uint8List _deriveKey(String password, Uint8List salt) {
    return _deriveKeyWithIterations(password, salt, _pbkdf2Iterations);
  }

  static Uint8List _deriveKeyWithIterations(
      String password, Uint8List salt, int iterations) {
    final pbkdf2 = pc.PBKDF2KeyDerivator(pc.HMac(pc.SHA256Digest(), 64))
      ..init(pc.Pbkdf2Parameters(salt, iterations, 32));

    return pbkdf2.process(Uint8List.fromList(utf8.encode(password)));
  }

  static Uint8List _randomBytes(int length) {
    final rng = Random.secure();
    return Uint8List.fromList(
      List.generate(length, (_) => rng.nextInt(256)),
    );
  }
}

/// Parsed data from a `.zest` import file.
class ZestImportData {
  final String label;
  final String host;
  final int port;
  final String protocol;
  final int colorIndex;
  final bool zlibCompression;
  final int keepAliveSeconds;
  final String? identityLabel;
  final String? username;
  final String? authMethod;
  final String? keyType;
  final int identityColorIndex;
  final String? password;
  final String? privateKeyPem;
  final List<ZestPortForward> portForwards;
  final bool isEncrypted;

  const ZestImportData({
    required this.label,
    required this.host,
    required this.port,
    required this.protocol,
    required this.colorIndex,
    required this.zlibCompression,
    required this.keepAliveSeconds,
    this.identityLabel,
    this.username,
    this.authMethod,
    this.keyType,
    this.identityColorIndex = 0,
    this.password,
    this.privateKeyPem,
    this.portForwards = const [],
    this.isEncrypted = false,
  });
}

/// Port forward rule from a `.zest` import.
class ZestPortForward {
  final String type;
  final String bindAddress;
  final int bindPort;
  final String remoteHost;
  final int remotePort;
  final bool autoStart;
  final String? label;

  const ZestPortForward({
    required this.type,
    required this.bindAddress,
    required this.bindPort,
    required this.remoteHost,
    required this.remotePort,
    required this.autoStart,
    this.label,
  });
}
