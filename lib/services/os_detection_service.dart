import 'dart:convert';

import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/models/os_kind.dart';
import 'package:zestssh/utils/logger.dart';

/// Detects the remote operating system over an SSH connection.
///
/// Strategy:
/// 1. Run `cat /etc/os-release 2>/dev/null || uname -s` on the remote host.
/// 2. Parse the `ID=` (and `ID_LIKE=`) fields from os-release output.
/// 3. Fall back to `uname -s` output for non-Linux systems (macOS, BSD).
///
/// Detection is best-effort: returns [OsKind.unknown] on failure.
class OsDetectionService {
  const OsDetectionService._();

  /// The most of the answer that is read: /etc/os-release is a few hundred
  /// bytes.
  static const int maxAnswerBytes = 64 * 1024;

  /// Detect the remote OS by running a command on the SSH client.
  ///
  /// Uses `client.runCapped()` to execute a one-shot command without
  /// interfering with the interactive shell session (dartssh2 opens a separate
  /// channel). It asks on every connection with nobody looking, so neither a
  /// long answer nor a late one costs more than this question: its channel is
  /// closed at the limit and at the timeout.
  static Future<OsKind> detect(SSHClient client) async {
    try {
      final result = await client.runCapped(
        'cat /etc/os-release 2>/dev/null || uname -s',
        maxBytes: maxAnswerBytes,
        timeout: const Duration(seconds: 5),
      );

      final output = utf8.decode(result, allowMalformed: true).trim();
      if (output.isEmpty) return OsKind.unknown;

      // os-release contains KEY=VALUE lines; uname returns a single word.
      if (output.contains('ID=')) {
        return parseOsRelease(output);
      }
      return parseUname(output);
    } catch (e) {
      AppLogger.warning('OS detection failed: $e');
      return OsKind.unknown;
    }
  }

  /// Parse `/etc/os-release` content and return the matching [OsKind].
  ///
  /// Looks at `ID=` first, then `ID_LIKE=` for derivatives
  /// (e.g. Pop!_OS sets `ID_LIKE=ubuntu debian`).
  static OsKind parseOsRelease(String content) {
    final lines = const LineSplitter().convert(content);

    String? id;
    String? idLike;

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.startsWith('ID=')) {
        id = _unquote(trimmed.substring(3)).toLowerCase();
      } else if (trimmed.startsWith('ID_LIKE=')) {
        idLike = _unquote(trimmed.substring(8)).toLowerCase();
      }
    }

    // Try exact match on ID first
    if (id != null) {
      final match = _matchDistroId(id);
      if (match != OsKind.unknown) return match;
    }

    // Try each token in ID_LIKE
    if (idLike != null) {
      for (final token in idLike.split(RegExp(r'\s+'))) {
        final match = _matchDistroId(token);
        if (match != OsKind.unknown) return match;
      }
    }

    // We got an os-release file, so it's definitely Linux, just unknown distro
    return OsKind.linux;
  }

  /// Parse `uname -s` output for non-Linux systems.
  static OsKind parseUname(String output) {
    final lower = output.toLowerCase().trim();

    if (lower.contains('darwin')) return OsKind.macos;
    if (lower.contains('freebsd')) return OsKind.freebsd;
    if (lower.contains('openbsd')) return OsKind.openbsd;
    if (lower.contains('netbsd')) return OsKind.netbsd;
    if (lower.contains('linux')) return OsKind.linux;
    if (lower.contains('cygwin') || lower.contains('mingw') || lower.contains('msys')) {
      return OsKind.windows;
    }

    return OsKind.unknown;
  }

  /// Match a distro ID string to an [OsKind] value.
  static OsKind _matchDistroId(String id) {
    return switch (id) {
      'ubuntu' => OsKind.ubuntu,
      'debian' => OsKind.debian,
      'fedora' => OsKind.fedora,
      'centos' => OsKind.centos,
      'rhel' || 'redhat' => OsKind.rhel,
      'arch' || 'archlinux' => OsKind.arch,
      'alpine' => OsKind.alpine,
      'nixos' => OsKind.nixos,
      'opensuse' || 'opensuse-leap' || 'opensuse-tumbleweed' || 'sles' => OsKind.opensuse,
      'gentoo' => OsKind.gentoo,
      'linuxmint' || 'mint' => OsKind.mint,
      'pop' => OsKind.pop,
      'manjaro' => OsKind.manjaro,
      'kali' => OsKind.kali,
      'raspbian' => OsKind.raspbian,
      'rocky' || 'rockylinux' => OsKind.rocky,
      'almalinux' || 'alma' => OsKind.alma,
      'void' => OsKind.void_,
      'slackware' => OsKind.slackware,
      'freebsd' => OsKind.freebsd,
      'openbsd' => OsKind.openbsd,
      'netbsd' => OsKind.netbsd,
      'synology' || 'dsm' => OsKind.synology,
      'unraid' => OsKind.unraid,
      'truenas' => OsKind.truenas,
      'openwrt' => OsKind.openwrt,
      'dd-wrt' || 'ddwrt' => OsKind.ddwrt,
      _ => OsKind.unknown,
    };
  }

  /// Strip surrounding quotes from a value (e.g. `"ubuntu"` -> `ubuntu`).
  static String _unquote(String value) {
    var s = value.trim();
    if (s.length >= 2 &&
        ((s.startsWith('"') && s.endsWith('"')) ||
            (s.startsWith("'") && s.endsWith("'")))) {
      s = s.substring(1, s.length - 1);
    }
    return s;
  }
}
