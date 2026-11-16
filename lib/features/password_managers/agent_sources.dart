/// Whose SSH agent holds an agent-backed key (3.0): the system's,
/// 1Password's or Bitwarden's. An identity names the source (synced); each
/// device finds where that agent listens itself, since the place differs by
/// system and by how the app was installed. KeePassXC has no agent of its
/// own: it adds its keys to the system agent.
///
/// Places checked 2026-09-25 against the vendors' documents. On Windows,
/// 1Password and Bitwarden both take over the OpenSSH agent's pipe
/// (`\\.\pipe\openssh-ssh-agent`), and the Windows "OpenSSH Authentication
/// Agent" service has to stay off for that: only one of them at a time.
///
/// Pure Dart, no Flutter or app imports, so it is testable on its own.
library;

/// The sources, as an identity's `agentSource` stores them.
enum AgentSource {
  system('system'),
  onePassword('1password'),
  bitwarden('bitwarden');

  const AgentSource(this.code);

  final String code;

  /// The stored value's source; null and anything unknown are the system's.
  static AgentSource of(String? code) {
    for (final s in values) {
      if (s.code == code) return s;
    }
    return AgentSource.system;
  }
}

/// The Windows OpenSSH agent's pipe, which 1Password and Bitwarden take over.
const String kWindowsAgentPipe = r'\\.\pipe\openssh-ssh-agent';

/// The places [source]'s agent may listen on this device, most likely
/// first; empty for the system agent (the OS default: the pipe on Windows,
/// `SSH_AUTH_SOCK` elsewhere).
List<String> agentSocketCandidates(
  AgentSource source, {
  required Map<String, String> environment,
  required bool isWindows,
  required bool isMacOS,
}) {
  if (source == AgentSource.system) return const [];
  if (isWindows) return const [kWindowsAgentPipe];
  final home = environment['HOME'];
  if (home == null || home.isEmpty) return const [];
  return switch (source) {
    AgentSource.onePassword => [
        if (isMacOS) '$home/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock' else '$home/.1password/agent.sock',
      ],
    AgentSource.bitwarden => [
        if (isMacOS) ...[
          // The App Store app is sandboxed; the one from the website is not.
          '$home/Library/Containers/com.bitwarden.desktop/Data/.bitwarden-ssh-agent.sock',
          '$home/.bitwarden-ssh-agent.sock',
        ] else ...[
          '$home/.bitwarden-ssh-agent.sock',
          '$home/snap/bitwarden/current/.bitwarden-ssh-agent.sock',
          '$home/.var/app/com.bitwarden.desktop/data/.bitwarden-ssh-agent.sock',
        ],
      ],
    AgentSource.system => const [],
  };
}

/// Where to reach an identity's agent: its device-local [override] when set,
/// else the first of [source]'s places that is there (or its most likely
/// one, so the error names where it looked), else null for the system's.
String? agentSocketFor(
  AgentSource source, {
  String? override,
  required Map<String, String> environment,
  required bool Function(String path) exists,
  required bool isWindows,
  required bool isMacOS,
}) {
  if (override != null && override.trim().isNotEmpty) return override.trim();
  final candidates = agentSocketCandidates(source, environment: environment, isWindows: isWindows, isMacOS: isMacOS);
  if (candidates.isEmpty) return null;
  for (final c in candidates) {
    if (isWindows || exists(c)) return c;
  }
  return candidates.first;
}
