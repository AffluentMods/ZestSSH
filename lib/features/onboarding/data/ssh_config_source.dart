import 'dart:io';

import 'package:zestssh/features/cloud_import/csv/csv_hosts.dart' show decodeCsvBytes, kCsvMaxBytes, kCsvMaxHosts;
import 'package:zestssh/features/cloud_import/import_away.dart';
import 'package:zestssh/features/onboarding/data/display_text_sanitizer.dart';
import 'package:zestssh/utils/platform_utils.dart';
import 'package:zestssh/utils/ssh_config_parser.dart';
import 'package:zestssh/utils/host_address.dart';

/// Why an entry from `~/.ssh/config` could not be turned into a connection.
///
/// Each value maps to a user-facing l10n string in the review UI
/// (`sshImportSkipReason*`). Keeping the enum separate from the copy lets
/// the parser stay UI-free and testable.
enum SshSkipReason { wildcard, host, port }

/// A concrete, importable host expanded from an SSH config `Host` block.
class OnboardingSshEntry {
  const OnboardingSshEntry({
    required this.alias,
    required this.hostname,
    this.port = 22,
    this.user,
    this.identityFile,
    this.proxyJump,
  });

  /// The (expanded) Host alias - always concrete, never a pattern.
  final String alias;
  final String hostname;
  final int port;
  final String? user;
  final String? identityFile;

  /// Raw `ProxyJump` value as written in the config (may be `user@host:port`).
  /// Resolved to a `connectViaId` at import time.
  final String? proxyJump;

  /// The bare host of [proxyJump] with any `user@` / `:port` stripped -
  /// used to match against other imported aliases / existing connections.
  /// Null where there is no route, or it is more than one host can stand for
  /// ([jumpHop]).
  String? get proxyJumpHost => jumpHop?.host;

  /// The one host [proxyJump] goes through, with the user and port written
  /// with it, where it names exactly one. Null for none (`none` included)
  /// and for a route of several hosts (`a,b`): the app links a host to the
  /// one host it connects through, and a route of several is connected
  /// through its last, which itself goes through the one before. Taking the
  /// first, as was done, made a route that leaves hosts out.
  ({String host, String? user, int? port})? get jumpHop {
    final raw = proxyJump?.trim();
    if (raw == null || raw.isEmpty || raw.toLowerCase() == 'none' || raw.contains(',')) return null;
    var h = raw;
    String? user;
    final at = h.lastIndexOf('@');
    if (at != -1) {
      user = h.substring(0, at);
      h = h.substring(at + 1);
    }
    // The port after it, and the brackets of an IPv6 address, are no part
    // of the host (cut at the first colon, an IPv6 one was its first group).
    final split = splitHostPort(h);
    final host = split?.host ?? h;
    if (host.isEmpty) return null;
    return (host: host, user: user == null || user.isEmpty ? null : user, port: split?.port);
  }

  /// Whether [proxyJump] names a route (anything but nothing and `none`).
  bool get hasJumpRoute {
    final raw = proxyJump?.trim();
    return raw != null && raw.isNotEmpty && raw.toLowerCase() != 'none';
  }
}

/// An entry the parser recognised but deliberately did not import, with the
/// reason so the review UI can be honest about what it left out.
class SshConfigSkip {
  const SshConfigSkip({required this.label, required this.reason});
  final String label;
  final SshSkipReason reason;
}

/// The outcome of parsing an SSH config: what is importable plus what was
/// skipped and why.
class SshConfigScanResult {
  const SshConfigScanResult({required this.entries, required this.skipped, this.cut = false});
  final List<OnboardingSshEntry> entries;
  final List<SshConfigSkip> skipped;

  /// More hosts came than are read ([kCsvMaxHosts], as from any host file).
  final bool cut;

  bool get isEmpty => entries.isEmpty && skipped.isEmpty;
  bool get hasImportable => entries.isNotEmpty;
}

/// What the config file [bytes] hold ([SshConfigSource.parse]).
SshConfigScanResult parseSshConfigBytes(List<int> bytes) => const SshConfigSource().parse(decodeCsvBytes(bytes));

/// [parseSshConfigBytes], off the screen's thread where there is much to read.
Future<SshConfigScanResult> parseSshConfigAway(List<int> bytes) =>
    importWorkAway(bytes.length, () => parseSshConfigBytes(bytes));

/// Locates + reads the user's `~/.ssh/config` and parses it into a reviewable
/// result. Pure of Flutter so it can be unit-tested and reused anywhere.
class SshConfigSource {
  const SshConfigSource();

  // Same allow-list the settings importer uses: rejects control chars,
  // whitespace, and shell metacharacters in a hostname.
  static final RegExp _validHost = RegExp(r'^[a-zA-Z0-9._:\[\]-]+$');

  /// The platform-specific path to the OpenSSH client config, or null when
  /// there's no usable home directory (typical on mobile).
  String? configPath() {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'];
    if (home == null || home.trim().isEmpty) return null;
    final sep = Platform.pathSeparator;
    return '$home$sep.ssh${sep}config';
  }

  /// Detect and parse `~/.ssh/config`. Returns null when no config file is
  /// present (or unreadable) so the caller can show a graceful "none found"
  /// state rather than an error. Never throws.
  Future<SshConfigScanResult?> detect() async {
    // On mobile there is effectively never a real user SSH config; HOME points
    // at the app sandbox. We still attempt (cheap) so the rare case works, but
    // a missing file is the normal, non-error outcome handled below.
    final path = configPath();
    return path == null ? null : detectAt(path);
  }

  /// [detect] for the config at [path]. One larger than a host file may be is
  /// left for the person to choose, which says why it is not read.
  Future<SshConfigScanResult?> detectAt(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      if (await file.length() > kCsvMaxBytes) return null;
      return await parseSshConfigAway(await file.readAsBytes());
    } catch (_) {
      // Unreadable (permissions, encoding) - treat as "none found".
      return null;
    }
  }

  /// Parse raw SSH config text into a reviewable result.
  ///
  /// Rules (F1):
  ///  * `Host a b c` expands to one entry per concrete alias.
  ///  * Wildcard-only host lines (`Host *`, `Host prod-*`) are skipped with a
  ///    wildcard reason - they describe many hosts, not one. What they say
  ///    still holds for the hosts they match, as does what stands before the
  ///    first `Host` line: each host gets the first value the file gives it,
  ///    as OpenSSH works it out ([SshConfigParser.valuesFor]).
  ///  * Invalid hostname / port produce a skip with the matching reason.
  ///  * `HostName`, `Port`, `User`, `IdentityFile`, `ProxyJump` are honoured.
  SshConfigScanResult parse(String content) {
    debugImportWorkHere++;
    final blocks = SshConfigParser.parse(content);
    final entries = <OnboardingSshEntry>[];
    final skipped = <SshConfigSkip>[];
    final index = SshConfigIndex(blocks);
    var cut = false;

    allBlocks:
    for (final block in blocks) {
      final hostSpec = block['Host'];
      if (hostSpec == null) continue; // Match blocks etc.
      // What stood before the first Host line: no host of its own, and not a
      // block the person wrote, so not one to list as left out.
      if (block.containsKey(SshConfigParser.global)) continue;

      // A Host line may list several patterns separated by whitespace.
      final tokens = hostSpec
          .split(RegExp(r'\s+'))
          .where((t) => t.isNotEmpty)
          .toList();
      if (tokens.isEmpty) continue;

      final concrete = tokens.where((t) => !_isPattern(t)).toList();
      if (concrete.isEmpty) {
        // Wildcard-only block (e.g. `Host *`). Report it once.
        skipped.add(SshConfigSkip(
          label: tokens.join(' '),
          reason: SshSkipReason.wildcard,
        ));
        continue;
      }

      for (final alias in concrete) {
        if (entries.length + skipped.length >= kCsvMaxHosts) {
          cut = true;
          break allBlocks;
        }
        // What the whole file says for this host: its own block, the blocks
        // of patterns that match it, and what stands before the first Host.
        final values = index.valuesFor(alias);
        final explicitHostName = values['HostName'];
        final portRaw = values['Port'];
        final user = values['User'];
        final identityFile = values['IdentityFile'];
        final proxyJump = values['ProxyJump'];

        // Port: default 22, but a present-and-invalid port is a hard skip.
        int port = 22;
        if (portRaw != null) {
          final parsed = int.tryParse(portRaw);
          if (parsed == null || parsed < 1 || parsed > 65535) {
            skipped.add(SshConfigSkip(
              label: alias,
              reason: SshSkipReason.port,
            ));
            continue;
          }
          port = parsed;
        }

        // The username renders on host cards via the linked identity, so hold it
        // to the app's display bar: strip control + bidi/RTL spoofing chars and
        // cap length (untrusted ~/.ssh/config). A value that sanitises to empty
        // (e.g. nothing but control chars) drops the username but still imports
        // the host - better than losing the server.
        final cleanedUser =
            user == null ? null : sanitizeDisplayText(user, maxLen: 256);
        final safeUser =
            (cleanedUser == null || cleanedUser.isEmpty) ? null : cleanedUser;

        // IdentityFile is surfaced verbatim in the connection note. Reject path
        // traversal outright, then hold the survivor to the same control/bidi and
        // length bar as every other imported free-text field.
        final String? safeIdentity;
        if (identityFile == null || identityFile.contains('..')) {
          safeIdentity = null;
        } else {
          final cleaned = sanitizeDisplayText(identityFile, maxLen: 1024);
          safeIdentity = cleaned.isEmpty ? null : cleaned;
        }

        final hostname = explicitHostName ?? alias;
        // Never a leading dash: it reads as an option (-oProxyCommand) wherever
        // it is passed later.
        if (!_validHost.hasMatch(hostname) || hostname.length > 253 || hostname.startsWith('-')) {
          skipped.add(SshConfigSkip(
            label: alias,
            reason: SshSkipReason.host,
          ));
          continue;
        }
        entries.add(OnboardingSshEntry(
          alias: alias,
          hostname: hostname,
          port: port,
          user: safeUser,
          identityFile: safeIdentity,
          proxyJump: proxyJump,
        ));
      }
    }

    return SshConfigScanResult(entries: entries, skipped: skipped, cut: cut);
  }

  /// True when a Host token is a pattern (wildcards / negation) rather than a
  /// concrete alias we can turn into a single connection.
  bool _isPattern(String token) =>
      token.contains('*') || token.contains('?') || token.startsWith('!');
}

/// Convenience for callers that only care whether a real desktop config is
/// even plausible (used to word the "none found" copy differently on mobile).
bool get sshConfigLikelyAvailable => isDesktopPlatform;
