/// Detected operating system of a remote SSH host.
///
/// Used to show an OS-specific icon and color next to saved connections.
/// Detection runs on first connect via [OsDetectionService] and the result
/// is cached in memory (not persisted to the database).
enum OsKind {
  // Linux distros
  ubuntu,
  debian,
  fedora,
  centos,
  rhel,
  arch,
  alpine,
  nixos,
  opensuse,
  gentoo,
  mint,
  pop,
  manjaro,
  kali,
  raspbian,
  rocky,
  alma,
  void_,
  slackware,

  // BSD
  freebsd,
  openbsd,
  netbsd,

  // Desktop/workstation
  macos,
  windows,

  // NAS / appliance
  synology,
  unraid,
  truenas,

  // Router / embedded
  openwrt,
  ddwrt,

  // Fallback
  linux, // generic Linux (detected via uname but distro unknown)
  unknown,
}
