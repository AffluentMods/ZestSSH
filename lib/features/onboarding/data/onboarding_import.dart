import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/features/onboarding/data/display_text_sanitizer.dart';
import 'package:zestssh/features/onboarding/data/ssh_config_source.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/utils/network_path.dart';

/// Outcome of importing a set of SSH-config entries.
class SshImportOutcome {
  const SshImportOutcome({required this.imported, required this.failedLimit});

  /// How many connections were actually created.
  final int imported;

  /// How many entries could not be created because the free-tier connection
  /// limit was hit. Non-zero means the user should be told to upgrade.
  final int failedLimit;
}

/// Create [Connection] rows for [entries], mapping SSH-config fields onto the
/// app's model:
///  * `HostName` → host, `Port` → port, `User` → a linked identity's username,
///    named after the host in the person's language ([l10n]).
///  * `IdentityFile` → best-effort, stored in the connection note so it isn't
///    lost (the key itself is added separately by the user).
///  * `ProxyJump` → `connectViaId` when the referenced host is among the
///    imported entries or an already-saved connection.
///
/// With [compatibilityMode], every host made has it on.
///
/// Imports every entry; there is no free-tier saved-connection limit. Any entry
/// that fails to create (e.g. malformed) is skipped and counted separately.
Future<SshImportOutcome> importSshEntries(
  WidgetRef ref,
  List<OnboardingSshEntry> entries, {
  required AppLocalizations l10n,
  Map<String, String> keys = const {},
  bool compatibilityMode = false,
}) async {
  final connectionCrud = ref.read(connectionCrudProvider);
  final identityCrud = ref.read(identityCrudProvider);

  // Existing connections let ProxyJump resolve against hosts the user already
  // had before this import (relevant when importing into a non-empty app).
  final List<ConnectionWithDetails> existing =
      ref.read(connectionsWithDetailsProvider).valueOrNull ?? const [];

  // alias -> created connection id, for ProxyJump resolution.
  final aliasToId = <String, String>{};
  var imported = 0;
  var failedLimit = 0;

  for (final entry in entries) {
    try {
      // The alias becomes both the connection label and the identity label and
      // renders on host cards. When a `HostName` directive is present the alias
      // never passes through the strict `_validHost` allow-list, so sanitise it
      // here (control + bidi/RTL spoofing chars, length cap) on BOTH paths.
      final safeLabel = sanitizeDisplayText(entry.alias, maxLen: 512);

      // Its key where it was read ([keys], by its IdentityFile): saved in the
      // identity, encrypted as every key is; else the path kept in its note.
      final pem = entry.identityFile == null ? null : keys[entry.identityFile];
      String? identityId;
      if (entry.user != null && entry.user!.isNotEmpty) {
        identityId = await identityCrud.create(
          label: l10n.sshConfigImportImportedIdentityLabel(safeLabel),
          username: entry.user!,
          authMethod: entry.identityFile != null ? 'publicKey' : 'password',
          privateKeyPem: pem,
        );
      }

      final note = entry.identityFile != null && (pem == null || identityId == null)
          ? 'IdentityFile: ${entry.identityFile}'
          : null;

      final id = await connectionCrud.create(
        label: safeLabel,
        host: entry.hostname,
        port: entry.port,
        identityId: identityId,
        note: note,
        compatibilityMode: compatibilityMode,
      );
      aliasToId[entry.alias] = id;
      imported++;
    } catch (_) {
      // No saved-connection limit anymore; only a malformed entry that fails
      // to create is skipped and counted.
      failedLimit++;
    }
  }

  // Second pass: wire ProxyJump → connectViaId now that ids exist.
  for (final entry in entries) {
    final jumpHost = entry.proxyJumpHost;
    final selfId = aliasToId[entry.alias];
    if (jumpHost == null || selfId == null) continue;

    String? targetId = aliasToId[jumpHost];
    targetId ??= _findExistingId(existing, jumpHost);
    if (targetId == null || targetId == selfId) continue;

    await connectionCrud.update(id: selfId, connectViaId: targetId);
  }

  return SshImportOutcome(imported: imported, failedLimit: failedLimit);
}

String? _findExistingId(List<ConnectionWithDetails> existing, String jumpHost) {
  for (final item in existing) {
    final conn = item.connection;
    if (conn.label == jumpHost || conn.host == jumpHost) {
      return conn.id;
    }
  }
  return null;
}

/// The private keys [entries] name by IdentityFile that can be read on this
/// computer: by the path as written (a `~` is the home folder, a relative one
/// is next to the config file, [configPath]), each a file that holds a
/// private key. Keyed by the IdentityFile as written. A key not found, not
/// readable or not a private key is left out (its path stays in the host's
/// note).
/// The most of a file read as a private key: a key is a few kilobytes.
const _kMaxKeyBytes = 64 * 1024;

Future<Map<String, String>> readIdentityKeys(List<OnboardingSshEntry> entries, {String? configPath}) async {
  final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  final base = configPath == null ? null : File(configPath).parent.path;
  final out = <String, String>{};
  for (final named in {for (final e in entries) ?e.identityFile}) {
    var path = named.trim();
    if (path.length > 1 && path.startsWith('"') && path.endsWith('"')) path = path.substring(1, path.length - 1);
    if (path.startsWith('~')) {
      if (home == null) continue;
      path = home + path.substring(1);
    }
    // Never a network path: opening one makes Windows sign in to that server
    // with the person's own credentials, and a config file can come from
    // someone else. (It is read as the file reaches its review, before Import
    // is pressed.)
    if (isNetworkPath(path)) continue;
    final absolute = path.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);
    // A relative path means nothing without the config file it sits beside:
    // it would be read from wherever the app happens to run.
    if (!absolute) {
      if (base == null) continue;
      path = '$base${Platform.pathSeparator}$path';
    }
    try {
      // Only a regular file (never a device, a pipe or a folder), and a key
      // is a few kilobytes: no more than that is ever read, whatever the
      // size said a moment before.
      final stat = await FileStat.stat(path);
      if (stat.type != FileSystemEntityType.file || stat.size > _kMaxKeyBytes) continue;
      final bytes = <int>[];
      await for (final chunk in File(path).openRead(0, _kMaxKeyBytes + 1)) {
        bytes.addAll(chunk);
      }
      if (bytes.length > _kMaxKeyBytes) continue;
      final text = utf8.decode(bytes, allowMalformed: true);
      if (RegExp(r'-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----').hasMatch(text)) out[named] = text;
    } catch (_) {
      // Not readable here: the path stays in the note.
    }
  }
  return out;
}

