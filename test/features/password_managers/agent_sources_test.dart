import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/password_managers/agent_sources.dart';

/// Where each password manager's SSH agent listens (3.0): each
/// device finds it itself; a path set on this device wins; the system agent
/// keeps the OS default.
void main() {
  String? where(AgentSource source, {Set<String> files = const {}, bool windows = false, bool mac = false, String? override}) =>
      agentSocketFor(source,
          override: override,
          environment: const {'HOME': '/home/a'},
          exists: files.contains,
          isWindows: windows,
          isMacOS: mac);

  test('stored values: unknown and missing are the system agent', () {
    expect(AgentSource.of('1password'), AgentSource.onePassword);
    expect(AgentSource.of('bitwarden'), AgentSource.bitwarden);
    expect(AgentSource.of(null), AgentSource.system);
    expect(AgentSource.of('/tmp/evil.sock'), AgentSource.system);
  });

  test('1Password: its own socket on macOS and Linux, the OpenSSH pipe on Windows', () {
    expect(where(AgentSource.onePassword, mac: true), '/home/a/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock');
    expect(where(AgentSource.onePassword), '/home/a/.1password/agent.sock');
    expect(where(AgentSource.onePassword, windows: true), kWindowsAgentPipe);
  });

  test('Bitwarden: the first of its places that is there', () {
    expect(where(AgentSource.bitwarden, mac: true, files: {'/home/a/.bitwarden-ssh-agent.sock'}),
        '/home/a/.bitwarden-ssh-agent.sock');
    expect(where(AgentSource.bitwarden, mac: true),
        '/home/a/Library/Containers/com.bitwarden.desktop/Data/.bitwarden-ssh-agent.sock',
        reason: 'none there: the most likely, so the error names where it looked');
    expect(where(AgentSource.bitwarden, files: {'/home/a/.var/app/com.bitwarden.desktop/data/.bitwarden-ssh-agent.sock'}),
        '/home/a/.var/app/com.bitwarden.desktop/data/.bitwarden-ssh-agent.sock');
    expect(where(AgentSource.bitwarden, windows: true), kWindowsAgentPipe);
  });

  test('the system agent keeps the default; a path set on this device wins', () {
    expect(where(AgentSource.system), isNull);
    expect(where(AgentSource.system, windows: true), isNull);
    expect(where(AgentSource.onePassword, override: ' /run/user/1000/op.sock '), '/run/user/1000/op.sock');
    expect(where(AgentSource.onePassword, override: '  '), '/home/a/.1password/agent.sock');
  });
}
