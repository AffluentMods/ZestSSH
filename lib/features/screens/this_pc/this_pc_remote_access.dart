/// Remote access to this PC (4.1, Windows): what it takes for another device
/// to reach this computer's desktop over Remote Desktop, read without asking
/// anything, and Remote Desktop turned on or off at the person's word, through
/// Windows' own administrator question.
///
/// What is read (no administrator needed):
///
/// * The edition. Windows Home cannot be reached over Remote Desktop (it has
///   no Remote Desktop server); Pro, Enterprise, Education and Server can.
/// * Whether Remote Desktop is on (`fDenyTSConnections` 0), whether it asks
///   for the account before the desktop starts (Network Level Authentication,
///   `UserAuthentication` 1) and its port.
/// * Whether the firewall lets it in: the inbound rules of Windows' own
///   "Remote Desktop" group, found by the group's resource name, which is the
///   same in every language.
///
/// What is changed, only from a button, through Windows' administrator
/// question (UAC), which the person may refuse: the same three things
/// Windows' own Settings > System > Remote Desktop switch changes (Remote
/// Desktop on, Network Level Authentication on, the group's firewall rules
/// on), or off again. Nothing else, and nothing without that question.
library;

import 'dart:convert';
import 'dart:io';

import 'package:zestssh/utils/windows_programs.dart' show windowsPowerShell;

/// The firewall's "Remote Desktop" group, by the resource name Windows gives
/// it in every language.
const kRdpFirewallGroup = '@FirewallAPI.dll,-28752';

/// Windows' "the person said no" to the administrator question
/// (ERROR_CANCELLED).
const kElevationRefused = 1223;

/// What was read of this PC.
class ThisPcState {
  const ThisPcState({
    required this.edition,
    required this.on,
    required this.nla,
    required this.port,
    required this.firewallOpen,
  });

  /// Windows' edition id (`EditionID`: Core, Professional, Enterprise,
  /// ServerStandard...), or null when it could not be read.
  final String? edition;

  /// Whether Remote Desktop takes connections.
  final bool on;

  /// Whether it asks for the account before the desktop starts.
  final bool nla;

  final int port;

  /// Whether an inbound firewall rule of the Remote Desktop group is on.
  final bool firewallOpen;

  /// Windows Home (EditionID Core, CoreN, CoreSingleLanguage,
  /// CoreCountrySpecific): no Remote Desktop server.
  bool get isHome => edition != null && edition!.toLowerCase().startsWith('core');

  /// Whether another device can reach this desktop as it is.
  bool get ready => !isHome && on && firewallOpen;

  static ThisPcState? fromJson(String text) {
    try {
      final j = jsonDecode(text.trim());
      if (j is! Map) return null;
      int? n(Object? v) => v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);
      return ThisPcState(
        edition: j['edition'] is String ? j['edition'] as String : null,
        // No value at all is how Windows leaves it: off.
        on: n(j['deny']) == 0,
        nla: n(j['nla']) == 1,
        port: n(j['port']) ?? 3389,
        firewallOpen: (n(j['firewall']) ?? 0) > 0,
      );
    } on FormatException {
      return null;
    }
  }
}

/// How a change came out.
enum ThisPcChange {
  /// Done.
  done,

  /// The person said no to Windows' administrator question.
  refused,

  /// Windows did not do it (a policy, a failure): nothing may have changed.
  failed,
}

/// Runs a PowerShell script, as tests replace it.
typedef PowerShellRunner = Future<ProcessResult> Function(List<String> arguments);

Future<ProcessResult> _runPowerShell(List<String> arguments) =>
    // By its full path: a powershell.exe in the current folder is not run.
    Process.run(windowsPowerShell, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', ...arguments]);

class ThisPcRemoteAccess {
  ThisPcRemoteAccess({PowerShellRunner? run}) : _run = run ?? _runPowerShell;

  final PowerShellRunner _run;

  /// The script that reads the state, printing one line of JSON.
  static const readScript = r'''
$ErrorActionPreference = 'SilentlyContinue'
$ts = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
$rdp = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
$ed = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID
$fw = @(Get-NetFirewallRule -Group '@FirewallAPI.dll,-28752' | Where-Object { $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' }).Count
[pscustomobject]@{ edition = $ed; deny = $ts.fDenyTSConnections; nla = $rdp.UserAuthentication; port = $rdp.PortNumber; firewall = $fw } | ConvertTo-Json -Compress
''';

  /// The script run as administrator to turn Remote Desktop [on] or off:
  /// what Windows' own switch changes, and nothing more.
  static String changeScript({required bool on}) => '''
\$ErrorActionPreference = 'Stop'
try {
  Set-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Terminal Server' -Name fDenyTSConnections -Value ${on ? 0 : 1}
  ${on ? "Set-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Terminal Server\\WinStations\\RDP-Tcp' -Name UserAuthentication -Value 1" : ''}
  ${on ? 'Enable' : 'Disable'}-NetFirewallRule -Group '$kRdpFirewallGroup'
  exit 0
} catch {
  exit 2
}
''';

  /// The script that asks Windows for an administrator to run [inner],
  /// waits for it and passes on how it ended ([kElevationRefused] where the
  /// person said no).
  static String elevateScript(String inner) {
    final encoded = base64.encode(_utf16le(inner));
    return '''
try {
  \$p = Start-Process -FilePath "\$env:SystemRoot\\System32\\WindowsPowerShell\\v1.0\\powershell.exe" -Verb RunAs -Wait -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand','$encoded'
  exit \$p.ExitCode
} catch {
  exit $kElevationRefused
}
''';
  }

  static List<int> _utf16le(String s) => [
        for (final unit in s.codeUnits) ...[unit & 0xff, unit >> 8],
      ];

  /// This PC's state, or null when it could not be read.
  Future<ThisPcState?> read() async {
    try {
      final r = await _run(['-Command', readScript]);
      if (r.exitCode != 0) return null;
      return ThisPcState.fromJson('${r.stdout}');
    } catch (_) {
      return null;
    }
  }

  /// Turns Remote Desktop [on] or off, after Windows' administrator question.
  Future<ThisPcChange> change({required bool on}) async {
    try {
      final r = await _run(['-Command', elevateScript(changeScript(on: on))]);
      return switch (r.exitCode) {
        0 => ThisPcChange.done,
        kElevationRefused => ThisPcChange.refused,
        _ => ThisPcChange.failed,
      };
    } catch (_) {
      return ThisPcChange.failed;
    }
  }
}

/// The addresses another device on this network can reach this PC at:
/// IPv4 addresses that are not the loopback or self-assigned (169.254).
Future<List<String>> thisPcAddresses() async {
  try {
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
    return reachableAddresses([for (final i in interfaces) for (final a in i.addresses) a.address]);
  } catch (_) {
    return const [];
  }
}

/// Of [addresses] (IPv4, as text), those another device could use: not the
/// loopback (127.x), not self-assigned (169.254.x).
List<String> reachableAddresses(Iterable<String> addresses) => [
      for (final a in addresses)
        if (!a.startsWith('127.') && !a.startsWith('169.254.')) a,
    ];
