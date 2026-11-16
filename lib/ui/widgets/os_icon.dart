import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:zestssh/models/os_kind.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/l10n/l10n_global.dart';

/// Displays an OS-specific icon with the distro's brand color.
///
/// Used in connection cards and tab bars to show what OS a server runs.
/// Falls back to generic icons (terminal, router, storage) when a
/// distro-specific icon isn't available in Material Icons.
class OsIconWidget extends StatelessWidget {
  final OsKind kind;
  final double size;

  const OsIconWidget({
    super.key,
    required this.kind,
    this.size = 20,
  });

  @override
  Widget build(BuildContext context) {
    return Icon(
      iconForOs(kind),
      size: size,
      color: colorForOs(kind),
    );
  }

  /// Brand color associated with each OS.
  static Color colorForOs(OsKind kind) {
    return switch (kind) {
      // Linux distros
      OsKind.ubuntu => const Color(0xFFE95420),
      OsKind.debian => const Color(0xFFA80030),
      OsKind.fedora => const Color(0xFF3C6EB4),
      OsKind.centos => const Color(0xFF932279),
      OsKind.rhel => const Color(0xFFEE0000),
      OsKind.arch => const Color(0xFF1793D1),
      OsKind.alpine => const Color(0xFF0D597F),
      OsKind.nixos => const Color(0xFF7EBAE4),
      OsKind.opensuse => const Color(0xFF73BA25),
      OsKind.gentoo => const Color(0xFF54487A),
      OsKind.mint => const Color(0xFF87CF3E),
      OsKind.pop => const Color(0xFF48B9C7),
      OsKind.manjaro => const Color(0xFF35BF5C),
      OsKind.kali => const Color(0xFF557C94),
      OsKind.raspbian => const Color(0xFFC51A4A),
      OsKind.rocky => const Color(0xFF10B981),
      OsKind.alma => const Color(0xFF0F4266),
      OsKind.void_ => const Color(0xFF478061),
      OsKind.slackware => const Color(0xFF354D73),

      // BSD
      OsKind.freebsd => const Color(0xFFAB2B28),
      OsKind.openbsd => const Color(0xFFF2CA30),
      OsKind.netbsd => const Color(0xFFFF6600),

      // Desktop
      OsKind.macos => const Color(0xFFA2AAAD),
      OsKind.windows => const Color(0xFF00A4EF),

      // NAS / appliance
      OsKind.synology => const Color(0xFFB5CC18),
      OsKind.unraid => const Color(0xFFE22828),
      OsKind.truenas => const Color(0xFF0095D5),

      // Router / embedded
      OsKind.openwrt => const Color(0xFF00B5E2),
      OsKind.ddwrt => const Color(0xFF4B8BBE),

      // Generic / fallback
      OsKind.linux => const Color(0xFFFCC624),
      OsKind.unknown => AppColors.brandOrange,
    };
  }

  /// Icon associated with each OS category.
  ///
  /// Material Icons doesn't include distro logos, so we use semantic
  /// icons that hint at the platform type.
  static IconData iconForOs(OsKind kind) {
    return switch (kind) {
      // macOS
      OsKind.macos => LucideIcons.laptop,

      // Windows
      OsKind.windows => LucideIcons.monitor,

      // Raspberry Pi
      OsKind.raspbian => LucideIcons.cpu,

      // NAS / storage appliances
      OsKind.synology || OsKind.unraid || OsKind.truenas => LucideIcons.hardDrive,

      // Router / network devices
      OsKind.openwrt || OsKind.ddwrt => LucideIcons.router,

      // BSD family
      OsKind.freebsd || OsKind.openbsd || OsKind.netbsd => LucideIcons.shield,

      // All Linux distros
      OsKind.ubuntu ||
      OsKind.debian ||
      OsKind.fedora ||
      OsKind.centos ||
      OsKind.rhel ||
      OsKind.arch ||
      OsKind.alpine ||
      OsKind.nixos ||
      OsKind.opensuse ||
      OsKind.gentoo ||
      OsKind.mint ||
      OsKind.pop ||
      OsKind.manjaro ||
      OsKind.kali ||
      OsKind.rocky ||
      OsKind.alma ||
      OsKind.void_ ||
      OsKind.slackware ||
      OsKind.linux =>
        LucideIcons.terminal,

      // Unknown
      OsKind.unknown => LucideIcons.server,
    };
  }

  /// Human-readable label for the OS.
  static String labelForOs(OsKind kind) {
    return switch (kind) {
      OsKind.ubuntu => 'Ubuntu',
      OsKind.debian => 'Debian',
      OsKind.fedora => 'Fedora',
      OsKind.centos => 'CentOS',
      OsKind.rhel => 'RHEL',
      OsKind.arch => 'Arch Linux',
      OsKind.alpine => 'Alpine',
      OsKind.nixos => 'NixOS',
      OsKind.opensuse => 'openSUSE',
      OsKind.gentoo => 'Gentoo',
      OsKind.mint => 'Linux Mint',
      OsKind.pop => 'Pop!_OS',
      OsKind.manjaro => 'Manjaro',
      OsKind.kali => 'Kali Linux',
      OsKind.raspbian => 'Raspbian',
      OsKind.rocky => 'Rocky Linux',
      OsKind.alma => 'AlmaLinux',
      OsKind.void_ => 'Void Linux',
      OsKind.slackware => 'Slackware',
      OsKind.freebsd => 'FreeBSD',
      OsKind.openbsd => 'OpenBSD',
      OsKind.netbsd => 'NetBSD',
      OsKind.macos => 'macOS',
      OsKind.windows => 'Windows',
      OsKind.synology => 'Synology DSM',
      OsKind.unraid => 'Unraid',
      OsKind.truenas => 'TrueNAS',
      OsKind.openwrt => 'OpenWrt',
      OsKind.ddwrt => 'DD-WRT',
      OsKind.linux => 'Linux',
      OsKind.unknown => gl10n.homeUnknown,
    };
  }
}
