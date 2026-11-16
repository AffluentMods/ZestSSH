import 'package:xml/xml.dart';
import 'package:zestssh/features/cloud_import/cloud_machine.dart' show cleanCloudText;
import 'package:zestssh/features/cloud_import/csv/csv_hosts.dart';
import 'package:zestssh/features/cloud_import/csv/paste_list.dart';
import 'package:zestssh/features/cloud_import/csv/rdp_file.dart';
import 'package:zestssh/features/cloud_import/import_away.dart';

/// Where a host file comes from: a spreadsheet, another SSH app's own file
/// (3.0, the Migration Assistant; FileZilla's and WinSCP's since 3.4, for
/// their FTP and FTPS sites), or a list pasted one host per line.
enum HostFileKind { csv, mobaxterm, securecrt, putty, filezilla, winscp, mremoteng, remmina, rdpfile, paste }

/// Whether [text] is MobaXterm's settings or sessions export: a `[Bookmarks`
/// section.
bool isMobaXtermFile(String text) => RegExp(r'^[ \t]*\[Bookmarks', multiLine: true).hasMatch(text);

/// Whether [text] is SecureCRT's settings export (XML from VanDyke) or one of
/// its session files (`S:"Hostname"=`).
bool isSecureCrtFile(String text) {
  final head = text.length > 4096 ? text.substring(0, 4096) : text;
  return head.contains('<VanDyke') || RegExp(r'^[ \t]*S:"Hostname"=', multiLine: true).hasMatch(text);
}

/// Whether [text] is PuTTY's sessions exported from the Windows registry.
bool isPuttyRegFile(String text) =>
    (text.contains('Windows Registry Editor') || text.contains('REGEDIT4')) && text.contains('SimonTatham');

/// Whether [text] is FileZilla's Site Manager (sitemanager.xml, or File >
/// Export): XML from FileZilla 3 with servers in it.
bool isFileZillaFile(String text) {
  final head = text.length > 4096 ? text.substring(0, 4096) : text;
  return head.contains('<FileZilla3') && text.contains('<Server');
}

/// Whether [text] is WinSCP's sites: its WinSCP.ini (or Export/Backup
/// Configuration), or its registry exported to a `.reg` file.
bool isWinScpFile(String text) =>
    RegExp(r'^[ \t]*\[Sessions\\', multiLine: true).hasMatch(text) ||
    (text.contains('Martin Prikryl') && RegExp(r'\\WinSCP 2\\Sessions\\', caseSensitive: false).hasMatch(text));

/// Whether [text] is mRemoteNG's connections file (confCons.xml, or File >
/// Export to File): XML whose root is its `Connections` with the file's
/// version.
bool isMRemoteNgFile(String text) {
  final head = text.length > 4096 ? text.substring(0, 4096) : text;
  return head.contains('<mrng:Connections') || (head.contains('<Connections') && head.contains('ConfVersion='));
}

/// Whether [text] is one of Remmina's connection files (a `.remmina` file):
/// its `[remmina]` section.
bool isRemminaFile(String text) => RegExp(r'^[ \t]*\[remmina\][ \t]*$', multiLine: true).hasMatch(text);

/// The kind of host file [text] is (import_detect.dart tells it from all else
/// a file may be): another app's, else a CSV file.
HostFileKind hostFileKindOf(String text) {
  if (isWinScpFile(text)) return HostFileKind.winscp;
  if (isPuttyRegFile(text)) return HostFileKind.putty;
  if (isFileZillaFile(text)) return HostFileKind.filezilla;
  if (isMobaXtermFile(text)) return HostFileKind.mobaxterm;
  if (isSecureCrtFile(text)) return HostFileKind.securecrt;
  if (isMRemoteNgFile(text)) return HostFileKind.mremoteng;
  if (isRemminaFile(text)) return HostFileKind.remmina;
  if (isRdpFile(text)) return HostFileKind.rdpfile;
  return HostFileKind.csv;
}

/// The hosts of [text], whichever kind of host file it is. [rdp]: this build
/// offers RDP hosts, so another app's RDP entries come in; else they are left
/// out, as every kind this app does not connect to.
CsvHostFile readHostFile(String text, {bool rdp = false, String? name}) {
  if (text.startsWith('﻿')) text = text.substring(1);
  return switch (hostFileKindOf(text)) {
    HostFileKind.csv => readCsvHosts(text, rdp: rdp),
    HostFileKind.mobaxterm => readMobaXtermHosts(text, rdp: rdp),
    HostFileKind.securecrt => readSecureCrtHosts(text),
    HostFileKind.putty => readPuttyRegHosts(text),
    HostFileKind.filezilla => readFileZillaHosts(text),
    HostFileKind.winscp => readWinScpHosts(text),
    HostFileKind.mremoteng => readMRemoteNgHosts(text, rdp: rdp),
    HostFileKind.remmina => readRemminaHosts(text, rdp: rdp),
    HostFileKind.rdpfile => readRdpFileHosts(text, rdp: rdp, fileName: name),
    HostFileKind.paste => readPastedHosts(text),
  };
}

/// What [bytes] hold as hosts, and as what they were read: as a list where they
/// were [pasted] into Paste a list and are no other app's file.
({CsvHostFile file, HostFileKind kind}) readHostBytes(
  List<int> bytes, {
  bool pasted = false,
  bool rdp = false,
  String? name,
}) {
  debugImportWorkHere++;
  final text = decodeCsvBytes(bytes);
  final kind = hostFileKindOf(text);
  if (pasted && kind == HostFileKind.csv) return (file: readPastedHosts(text), kind: HostFileKind.paste);
  return (file: readHostFile(text, rdp: rdp, name: name), kind: kind);
}

/// [readHostBytes], off the screen's thread where there is much to read.
Future<({CsvHostFile file, HostFileKind kind})> readHostBytesAway(
  List<int> bytes, {
  bool pasted = false,
  bool rdp = false,
  String? name,
}) =>
    importWorkAway(bytes.length, () => readHostBytes(bytes, pasted: pasted, rdp: rdp, name: name));

/// A pasted list's hosts ([parsePasteList]), as a host file's lines: each
/// host checked as a CSV line is; a line that is no host kept, as itself,
/// with its line number and the problem.
CsvHostFile readPastedHosts(String text) {
  final read = parsePasteList(text);
  if (read.hosts.isEmpty && read.errors.isEmpty) return const CsvHostFile(problem: CsvFileProblem.empty);
  final rows = <CsvHostRow>[
    for (final h in read.hosts)
      importedHostRow(line: h.line, name: h.host, host: h.host, port: h.port, user: h.user),
    for (final e in read.errors)
      // Shown as it was pasted, but never with what would hide or reorder
      // the text beside it.
      CsvHostRow(line: e.line, name: cleanCloudText(e.text, max: 255), host: '', problem: CsvRowProblem.badHost),
  ]..sort((a, b) => a.line.compareTo(b.line));
  final cut = rows.length > kCsvMaxHosts;
  return CsvHostFile(rows: cut ? rows.take(kCsvMaxHosts).toList() : rows, cut: cut);
}

/// MobaXterm's sessions (its MobaXterm.ini, or a `.mxtsessions` export):
/// each `[Bookmarks...]` section is a folder (`SubRep=`, its path), and each
/// session in it a line `name=#icon#kind%host%port%user%...`, its icon the
/// kind's own unless someone changed it. SSH (icon 109, kind 0) and Telnet
/// (98) are taken, SFTP (icon 140, kind 7) as a host that is SFTP only, and
/// FTP (icon 130, kind 6) as an FTPS host (3.4; never plain FTP: explicit TLS,
/// implicit on port 990). VNC sessions (icon 128, kind 5) come in as remote
/// screens (4.0), and RDP sessions (icon 91, kind 4) where this build offers
/// RDP ([rdp]); its other kinds (a serial line, a browser, a shell...) are not
/// hosts this app connects to, and are left out.
CsvHostFile readMobaXtermHosts(String text, {bool rdp = false}) {
  if (text.length > kCsvMaxBytes) return const CsvHostFile(problem: CsvFileProblem.tooLarge);
  final rows = <CsvHostRow>[];
  final lines = text.split(RegExp(r'\r\n|\r|\n'));
  var inBookmarks = false;
  String? folder;
  var cut = false;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.startsWith('[')) {
      inBookmarks = line.startsWith('[Bookmarks');
      folder = null;
      continue;
    }
    if (!inBookmarks || line.isEmpty) continue;
    final eq = line.indexOf('=');
    if (eq <= 0) continue;
    final key = line.substring(0, eq).trim();
    final value = line.substring(eq + 1);
    if (key == 'SubRep') {
      final path = value.trim();
      folder = path.isEmpty ? null : path.split(RegExp(r'[\\/]')).where((s) => s.trim().isNotEmpty).join(' / ');
      continue;
    }
    if (key == 'ImgNum') continue;
    // A session: #icon#kind%host%port%user%...
    final m = RegExp(r'^#(\d+)#(\d+)%([^%]*)%([^%]*)%([^%]*)').firstMatch(value);
    if (m == null) continue;
    final kind = _mobaXtermProtocol(icon: m.group(1)!, kind: m.group(2)!);
    if (kind == null || (kind == kImportRdp && !rdp)) continue;
    if (rows.length >= kCsvMaxHosts) {
      cut = true;
      break;
    }
    final port = int.tryParse(m.group(4)!.trim());
    final ftps = kind == 'ftp' ? ftpsImportOf('ftp', port: port) : null;
    rows.add(importedHostRow(
      line: i + 1,
      name: key,
      host: m.group(3)!,
      // (No port in the line: the kind's own, which importedHostRow knows.)
      port: port ?? (ftps == null && !csvIsScreen(kind) ? 22 : null),
      // A VNC session's third field is not an account's name.
      user: kind == 'vnc' ? null : m.group(5),
      group: folder,
      protocol: ftps?.protocol ?? kind,
      wasPlainFtp: ftps?.wasPlain ?? false,
    ));
  }
  if (rows.isEmpty && !cut) return const CsvHostFile(problem: CsvFileProblem.empty);
  return CsvHostFile(rows: rows, cut: cut);
}

/// What a MobaXterm session is, as this app has it: its kind where it is
/// one of SSH's (0), FTP's (6) and SFTP's (7), which its icon may be changed
/// away from; else its icon, as each kind has it by itself (SSH 109, Telnet
/// 98, FTP 130, SFTP 140, RDP 91, VNC 128). `ftp` for FTP, which comes in as
/// FTPS. Null for a kind this app does not connect to.
String? _mobaXtermProtocol({required String icon, required String kind}) => switch (kind) {
      '0' => 'ssh',
      '4' => kImportRdp,
      '5' => 'vnc',
      '6' => 'ftp',
      '7' => 'sftp',
      _ => switch (icon) {
          '109' => 'ssh',
          '98' => 'telnet',
          '130' => 'ftp',
          '140' => 'sftp',
          '91' => kImportRdp,
          '128' => 'vnc',
          _ => null,
        },
    };

/// PuTTY's saved sessions, exported from the registry to a `.reg` file on
/// Windows (regedit writes them in UTF-16; [decodeCsvBytes] reads that): one
/// section per session, `...\SimonTatham\PuTTY\Sessions\name`, its name
/// escaped as a URL, with `"HostName"="..."`, `"PortNumber"=dword:00000016`,
/// `"UserName"="..."` and `"Protocol"="ssh"`. SSH and Telnet sessions are
/// taken; others (serial, raw, rlogin) are left out, as is PuTTY's Default
/// Settings, which is no host. It holds no passwords.
CsvHostFile readPuttyRegHosts(String text) {
  if (text.length > kCsvMaxBytes) return const CsvHostFile(problem: CsvFileProblem.tooLarge);
  final section = RegExp(r'\\SimonTatham\\PuTTY\\Sessions\\([^\\\]]+)\]$', caseSensitive: false);
  final value = RegExp(r'^"([^"]+)"=(.*)$');
  final rows = <CsvHostRow>[];
  var cut = false;
  String? name;
  var at = 0;
  final found = <String, String>{};

  void finish() {
    final session = name;
    if (session == null || session == 'Default Settings' || cut) return;
    var host = (found['HostName'] ?? '').trim();
    if (host.isEmpty) return;
    final protocol = switch ((found['Protocol'] ?? 'ssh').toLowerCase()) {
      'ssh' => 'ssh',
      'telnet' => 'telnet',
      _ => null,
    };
    if (protocol == null) return;
    if (rows.length >= kCsvMaxHosts) {
      cut = true;
      return;
    }
    // PuTTY takes user@host in its host field.
    var user = found['UserName'];
    final atSign = host.lastIndexOf('@');
    if (atSign > 0) {
      user = (user == null || user.isEmpty) ? host.substring(0, atSign) : user;
      host = host.substring(atSign + 1);
    }
    final port = found['PortNumber'];
    rows.add(importedHostRow(
      line: at,
      name: session,
      host: host,
      port: port == null ? null : int.tryParse(port, radix: 16),
      user: user,
      protocol: protocol,
    ));
  }

  final lines = text.split(RegExp(r'\r\n|\r|\n'));
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.startsWith('[')) {
      finish();
      found.clear();
      at = i + 1;
      final m = section.firstMatch(line);
      if (m == null) {
        name = null;
      } else {
        try {
          name = Uri.decodeComponent(m.group(1)!);
        } catch (_) {
          name = m.group(1);
        }
      }
      continue;
    }
    if (name == null) continue;
    final m = value.firstMatch(line);
    if (m == null) continue;
    final raw = m.group(2)!;
    if (raw.startsWith('dword:')) {
      found[m.group(1)!] = raw.substring(6);
    } else if (raw.length >= 2 && raw.startsWith('"') && raw.endsWith('"')) {
      found[m.group(1)!] = raw.substring(1, raw.length - 1).replaceAll(r'\\', '\\').replaceAll(r'\"', '"');
    }
  }
  finish();
  if (rows.isEmpty && !cut) return const CsvHostFile(problem: CsvFileProblem.empty);
  return CsvHostFile(rows: rows, cut: cut);
}

/// What a SecureCRT (or SecureFX) session's "Protocol Name" is, as this app
/// has it: SSH1 and SSH2 as SSH, Telnet, SFTP (SecureFX's file sessions,
/// in the same session files) as a host that is SFTP only, and SecureFX's FTP
/// and FTP over TLS as FTPS (`ftp` here; [ftpsImportOf] decides explicit or
/// implicit by the port). Null for any other (serial, RDP).
String? _secureCrtProtocol(String? protocolName) {
  final name = (protocolName ?? 'SSH2').toUpperCase();
  if (name.startsWith('SSH')) return 'ssh';
  if (ftpsImportOf(name) != null) return 'ftp';
  return switch (name) {
    'TELNET' => 'telnet',
    'SFTP' => 'sftp',
    _ => null,
  };
}

/// [protocolName] (SecureCRT's or SecureFX's) as the host comes in, on
/// [port]: an FTPS host for FTP of any kind, else [_secureCrtProtocol]'s.
({String protocol, bool wasPlain}) _secureCrtImport(String? protocolName, int? port) {
  final ftps = ftpsImportOf(protocolName ?? '', port: port);
  if (ftps != null) return ftps;
  return (protocol: _secureCrtProtocol(protocolName)!, wasPlain: false);
}

/// The settings that hold a session's port, its protocol's own first: every
/// session file carries every protocol's port (it starts as a copy of
/// Default.ini), so a Telnet session has `[SSH2] Port` 22 beside its own
/// `Port`.
List<String> _secureCrtPortKeys(String? protocolName) => switch ((protocolName ?? 'SSH2').toUpperCase()) {
      'TELNET' => const ['Port'],
      'SFTP' => const ['[SFTP] Port', '[SSH2] Port', 'Port'],
      'SSH1' => const ['[SSH1] Port', 'Port'],
      // (FTP's own only: the shared Port is Telnet's where it is not FTP's.)
      final name when ftpsImportOf(name) != null => const ['[FTP] Port', '[FTPS] Port', '[FTP/TLS] Port'],
      _ => const ['[SSH2] Port', '[SFTP] Port', 'Port'],
    };

/// SecureCRT's sessions: its settings export (Tools > Export Settings, an
/// XML file whose `Sessions` key holds a key per session, in keys per
/// folder) or a session's own `.ini` file (`S:"Hostname"=`, `D:"[SSH2] Port"=`
/// in hexadecimal, `S:"Username"=`, `S:"Protocol Name"=`). SSH2 and Telnet
/// sessions are taken, and SFTP ones (SecureFX's) as hosts that are SFTP
/// only ([_secureCrtProtocol]); others (serial, RDP) are left out.
CsvHostFile readSecureCrtHosts(String text) {
  if (text.length > kCsvMaxBytes) return const CsvHostFile(problem: CsvFileProblem.tooLarge);
  if (!text.contains('<VanDyke')) {
    final row = _secureCrtIni(text);
    return row == null ? const CsvHostFile(problem: CsvFileProblem.empty) : CsvHostFile(rows: [row]);
  }
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(text);
  } on XmlException {
    return const CsvHostFile(problem: CsvFileProblem.empty);
  }
  final sessions = doc.findAllElements('key').where((k) => k.getAttribute('name') == 'Sessions').firstOrNull;
  if (sessions == null) return const CsvHostFile(problem: CsvFileProblem.empty);
  final rows = <CsvHostRow>[];
  var cut = false;
  var line = 0;

  String? valueOf(XmlElement key, String name) {
    for (final child in key.childElements) {
      if (child.getAttribute('name') == name) return child.innerText.trim();
    }
    return null;
  }

  void walk(XmlElement key, List<String> path) {
    for (final child in key.childElements.where((e) => e.name.local == 'key')) {
      if (cut) return;
      final name = child.getAttribute('name') ?? '';
      final host = valueOf(child, 'Hostname');
      if (host == null) {
        // A folder.
        walk(child, [...path, name]);
        continue;
      }
      line++;
      // The Default session is SecureCRT's settings for new ones, no host.
      if (host.isEmpty) continue;
      final protocolName = valueOf(child, 'Protocol Name');
      final protocol = _secureCrtProtocol(protocolName);
      if (protocol == null) continue;
      if (rows.length >= kCsvMaxHosts) {
        cut = true;
        return;
      }
      final portText = _secureCrtPortKeys(protocolName).map((k) => valueOf(child, k)).nonNulls.firstOrNull;
      final port = portText == null ? null : int.tryParse(portText);
      final taken = _secureCrtImport(protocolName, port);
      rows.add(importedHostRow(
        line: line,
        name: name,
        host: host,
        port: port,
        user: valueOf(child, 'Username'),
        group: path.isEmpty ? null : path.join(' / '),
        protocol: taken.protocol,
        wasPlainFtp: taken.wasPlain,
      ));
    }
  }

  walk(sessions, const []);
  if (rows.isEmpty && !cut) return const CsvHostFile(problem: CsvFileProblem.empty);
  return CsvHostFile(rows: rows, cut: cut);
}

/// A SecureCRT session file: one host, its name not in the file.
CsvHostRow? _secureCrtIni(String text) {
  String? s(String name) => RegExp('^S:"${RegExp.escape(name)}"=(.*)\$', multiLine: true).firstMatch(text)?.group(1)?.trim();
  String? d(String name) => RegExp('^D:"${RegExp.escape(name)}"=([0-9a-fA-F]+)', multiLine: true).firstMatch(text)?.group(1);
  final host = s('Hostname');
  if (host == null || host.isEmpty) return null;
  final protocolName = s('Protocol Name');
  if (_secureCrtProtocol(protocolName) == null) return null;
  final portHex = _secureCrtPortKeys(protocolName).map(d).nonNulls.firstOrNull;
  final port = portHex == null ? null : int.tryParse(portHex, radix: 16);
  final taken = _secureCrtImport(protocolName, port);
  return importedHostRow(
    line: 1,
    name: host,
    host: host,
    port: port,
    user: s('Username'),
    protocol: taken.protocol,
    wasPlainFtp: taken.wasPlain,
  );
}

/// FileZilla's Site Manager (3.4): its sitemanager.xml, or the file File >
/// Export writes, `<Server>`s in `<Folder>`s (a folder's name is its own
/// text), each with `<Host>`, `<Port>`, `<User>`, `<Name>` and `<Protocol>`:
/// 0 FTP (TLS where the server has it), 6 plain FTP, 4 FTPES (explicit TLS)
/// and 3 FTPS (implicit TLS) come in as FTPS hosts, never plain FTP
/// ([ftpsImportOf]); 1 SFTP as a host that is SFTP only; the rest (HTTP, S3,
/// WebDAV and the other clouds) are left out. Its `<Pass>` is never read: a
/// password stays in FileZilla.
CsvHostFile readFileZillaHosts(String text) {
  if (text.length > kCsvMaxBytes) return const CsvHostFile(problem: CsvFileProblem.tooLarge);
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(text);
  } on XmlException {
    return const CsvHostFile(problem: CsvFileProblem.empty);
  }
  final rows = <CsvHostRow>[];
  var cut = false;
  var line = 0;

  String? child(XmlElement e, String name) => e.childElements.where((c) => c.name.local == name).firstOrNull?.innerText.trim();

  void walk(XmlElement parent, List<String> path) {
    for (final e in parent.childElements) {
      if (cut) return;
      if (e.name.local == 'Folder') {
        final name = e.children.whereType<XmlText>().map((t) => t.value).join().trim();
        walk(e, name.isEmpty ? path : [...path, name]);
        continue;
      }
      if (e.name.local != 'Server') continue;
      line++;
      final port = int.tryParse(child(e, 'Port') ?? '');
      final ({String protocol, bool wasPlain})? taken = switch (child(e, 'Protocol') ?? '0') {
        '0' || '6' => ftpsImportOf('ftp', port: port),
        '4' => ftpsImportOf('ftpes', port: port),
        '3' => ftpsImportOf('ftpsimplicit', port: port),
        '1' => (protocol: 'sftp', wasPlain: false),
        _ => null,
      };
      if (taken == null) continue;
      if (rows.length >= kCsvMaxHosts) {
        cut = true;
        return;
      }
      final host = child(e, 'Host') ?? '';
      rows.add(importedHostRow(
        line: line,
        name: child(e, 'Name') ?? host,
        host: host,
        port: port,
        user: child(e, 'User'),
        group: path.isEmpty ? null : path.join(' / '),
        protocol: taken.protocol,
        wasPlainFtp: taken.wasPlain,
      ));
    }
  }

  for (final servers in doc.findAllElements('Servers').followedBy(doc.findAllElements('RecentServers'))) {
    walk(servers, const []);
  }
  if (rows.isEmpty && !cut) return const CsvHostFile(problem: CsvFileProblem.empty);
  return CsvHostFile(rows: rows, cut: cut);
}

/// WinSCP's sites (3.4): its WinSCP.ini, or the file Tools > Export/Backup
/// Configuration writes, one `[Sessions\folder/name]` section per site (its
/// path escaped as a URL), or the same from the registry in a `.reg` file
/// (`...\Martin Prikryl\WinSCP 2\Sessions\...`, numbers as `dword:`). Each has
/// `HostName`, `PortNumber`, `UserName`, `FSProtocol` (0 SCP, 1 and 2 SFTP,
/// the default; 5 FTP; 6 WebDAV, 7 S3) and for FTP `Ftps` (0 none, 1 implicit
/// TLS, 2 and 3 explicit). FTP of every kind comes in as an FTPS host, never
/// plain FTP ([ftpsImportOf]); SFTP and SCP as hosts that are SFTP only;
/// WebDAV and S3 are left out, as is WinSCP's Default Settings. Its passwords
/// are never read.
CsvHostFile readWinScpHosts(String text) {
  if (text.length > kCsvMaxBytes) return const CsvHostFile(problem: CsvFileProblem.tooLarge);
  final ini = RegExp(r'^\[Sessions\\(.+)\]$');
  final reg = RegExp(r'\\WinSCP 2\\Sessions\\([^\\\]]+)\]$', caseSensitive: false);
  final iniValue = RegExp(r'^([A-Za-z0-9]+)=(.*)$');
  final regValue = RegExp(r'^"([^"]+)"=(.*)$');
  final rows = <CsvHostRow>[];
  var cut = false;
  String? name;
  var at = 0;
  final found = <String, String>{};

  String decode(String s) {
    try {
      return Uri.decodeComponent(s);
    } catch (_) {
      return s;
    }
  }

  void finish() {
    final session = name;
    if (session == null || session == 'Default Settings' || cut) return;
    final host = (found['HostName'] ?? '').trim();
    if (host.isEmpty) return;
    final port = int.tryParse(found['PortNumber'] ?? '');
    final ({String protocol, bool wasPlain})? taken = switch (found['FSProtocol'] ?? '1') {
      '0' || '1' || '2' => (protocol: 'sftp', wasPlain: false),
      '5' => switch (found['Ftps'] ?? '0') {
          '1' => ftpsImportOf('ftpsimplicit', port: port),
          '2' || '3' => ftpsImportOf('ftpes', port: port),
          _ => ftpsImportOf('ftp', port: port),
        },
      _ => null,
    };
    if (taken == null) return;
    if (rows.length >= kCsvMaxHosts) {
      cut = true;
      return;
    }
    final parts = session.split('/').map(decode).where((p) => p.trim().isNotEmpty).toList();
    final user = found['UserName'];
    rows.add(importedHostRow(
      line: at,
      name: parts.isEmpty ? host : parts.last,
      host: decode(host),
      port: port,
      user: user == null ? null : decode(user),
      group: parts.length > 1 ? parts.sublist(0, parts.length - 1).join(' / ') : null,
      protocol: taken.protocol,
      wasPlainFtp: taken.wasPlain,
    ));
  }

  final lines = text.split(RegExp(r'\r\n|\r|\n'));
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.startsWith('[')) {
      finish();
      found.clear();
      at = i + 1;
      name = (ini.firstMatch(line) ?? reg.firstMatch(line))?.group(1);
      continue;
    }
    if (name == null) continue;
    final r = regValue.firstMatch(line);
    if (r != null) {
      final raw = r.group(2)!;
      if (raw.startsWith('dword:')) {
        found[r.group(1)!] = '${int.tryParse(raw.substring(6), radix: 16) ?? ''}';
      } else if (raw.length >= 2 && raw.startsWith('"') && raw.endsWith('"')) {
        found[r.group(1)!] = raw.substring(1, raw.length - 1).replaceAll(r'\\', '\\').replaceAll(r'\"', '"');
      }
      continue;
    }
    final m = iniValue.firstMatch(line);
    if (m != null) found[m.group(1)!] = m.group(2)!.trim();
  }
  finish();
  if (rows.isEmpty && !cut) return const CsvHostFile(problem: CsvFileProblem.empty);
  return CsvHostFile(rows: rows, cut: cut);
}

/// What mRemoteNG's `Protocol` is, as this app has it: SSH (1 and 2), Telnet,
/// VNC, and RDP where this build offers it. Null for any other (Rlogin, raw,
/// HTTP, ICA, an outside program, PowerShell).
String? _mRemoteNgProtocol(String? name, {required bool rdp}) => switch ((name ?? '').toUpperCase()) {
      'SSH2' || 'SSH1' => 'ssh',
      'TELNET' => 'telnet',
      'VNC' => 'vnc',
      'RDP' => rdp ? kImportRdp : null,
      _ => null,
    };

/// mRemoteNG's connections (4.0): its confCons.xml, or File > Export to File.
/// `<Node>`s inside `<Node Type="Container">`s (a container's `Name` is the
/// folder), each connection with `Name`, `Hostname`, `Protocol`, `Port`,
/// `Username` and `Domain`. A value a node inherits from its folder
/// (`InheritPort="true"` and the like) is the folder's. SSH, Telnet and VNC
/// connections come in, and RDP ones where this build offers RDP ([rdp]); the
/// rest are left out. Its `Password` is never read (it is encrypted with
/// mRemoteNG's own password, and stays there). A file encrypted as a whole
/// holds no node to read, and reads as empty.
CsvHostFile readMRemoteNgHosts(String text, {bool rdp = false}) {
  if (text.length > kCsvMaxBytes) return const CsvHostFile(problem: CsvFileProblem.tooLarge);
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(text);
  } on XmlException {
    return const CsvHostFile(problem: CsvFileProblem.empty);
  }
  final rows = <CsvHostRow>[];
  var cut = false;
  var line = 0;

  String? attr(XmlElement e, String name) {
    final v = e.getAttribute(name)?.trim();
    return v == null || v.isEmpty ? null : v;
  }

  bool inherits(XmlElement e, String what) => (e.getAttribute('Inherit$what') ?? '').toLowerCase() == 'true';

  // What a node has, or its folder's where it says it inherits it.
  String? own(XmlElement e, String name, Map<String, String?> folder) =>
      inherits(e, name) ? folder[name] : attr(e, name);

  void walk(XmlElement parent, List<String> path, Map<String, String?> folder, int depth) {
    // (No real file nests folders this deep; a made-up one stops here.)
    if (depth > 64) return;
    for (final e in parent.childElements) {
      if (cut) return;
      if (e.name.local != 'Node') continue;
      final here = {
        for (final name in const ['Protocol', 'Port', 'Username', 'Domain']) name: own(e, name, folder),
      };
      if ((attr(e, 'Type') ?? '').toLowerCase() == 'container') {
        final name = attr(e, 'Name');
        walk(e, name == null ? path : [...path, name], here, depth + 1);
        continue;
      }
      line++;
      final protocol = _mRemoteNgProtocol(here['Protocol'], rdp: rdp);
      if (protocol == null) continue;
      if (rows.length >= kCsvMaxHosts) {
        cut = true;
        return;
      }
      final host = attr(e, 'Hostname') ?? '';
      final user = here['Username'];
      final domain = here['Domain'];
      rows.add(importedHostRow(
        line: line,
        name: attr(e, 'Name') ?? host,
        host: host,
        // A port that is written and is no number is said, not made the usual one.
        port: here['Port'] == null ? null : (int.tryParse(here['Port']!) ?? 0),
        // A Windows account with its domain, as an RDP host's key takes it.
        user: user == null
            ? null
            : (protocol == kImportRdp && domain != null && !user.contains(r'\') && !user.contains('@')
                ? '$domain\\$user'
                : user),
        group: path.isEmpty ? null : path.join(' / '),
        protocol: protocol,
      ));
    }
  }

  walk(doc.rootElement, const [], const {}, 0);
  if (rows.isEmpty && !cut) return const CsvHostFile(problem: CsvFileProblem.empty);
  return CsvHostFile(rows: rows, cut: cut);
}

/// What a Remmina file's `protocol` is, as this app has it. Null for any
/// other (SPICE, NX, X2Go, a VNC listener, a web page).
String? _remminaProtocol(String? name, {required bool rdp}) => switch ((name ?? '').toUpperCase()) {
      'SSH' => 'ssh',
      'SFTP' => 'sftp',
      'VNC' => 'vnc',
      'RDP' => rdp ? kImportRdp : null,
      _ => null,
    };

/// One of Remmina's connection files (4.0; a `.remmina` file, one host each):
/// its `[remmina]` section's `name`, `group`, `server` (an address, with its
/// port after a colon where it has one), `protocol`, `username` and `domain`.
/// SSH, SFTP and VNC connections come in, and RDP ones where this build
/// offers RDP ([rdp]). Its `password` is never read: it is encrypted with a
/// key Remmina keeps, and stays there. A VNC server named with a display
/// number (`host:1`) is on port 5900 and that number.
CsvHostFile readRemminaHosts(String text, {bool rdp = false}) {
  if (text.length > kCsvMaxBytes) return const CsvHostFile(problem: CsvFileProblem.tooLarge);
  final found = <String, String>{};
  var inSection = false;
  var lineOfServer = 1;
  final lines = text.split(RegExp(r'\r\n|\r|\n'));
  for (var i = 0; i < lines.length && i < 4000; i++) {
    final line = lines[i].trim();
    if (line.startsWith('[')) {
      inSection = line.toLowerCase() == '[remmina]';
      continue;
    }
    if (!inSection || line.isEmpty || line.startsWith('#') || line.startsWith(';')) continue;
    final eq = line.indexOf('=');
    if (eq <= 0) continue;
    final key = line.substring(0, eq).trim().toLowerCase();
    // The first of each counts; the password is not kept even in memory.
    if (key == 'password' || found.containsKey(key)) continue;
    if (const {'name', 'group', 'server', 'protocol', 'username', 'domain'}.contains(key)) {
      found[key] = line.substring(eq + 1).trim();
      if (key == 'server') lineOfServer = i + 1;
    }
  }
  final protocol = _remminaProtocol(found['protocol'], rdp: rdp);
  if (protocol == null) return const CsvHostFile(problem: CsvFileProblem.empty);
  var server = found['server'] ?? '';
  int? port;
  // [v6]:port, host:port, or an address alone (an IPv6 address has more colons than one).
  final bracket = RegExp(r'^\[([^\]]*)\](?::(\d{1,5}))?$').firstMatch(server);
  if (bracket != null) {
    server = bracket.group(1)!;
    port = int.tryParse(bracket.group(2) ?? '');
  } else if (':'.allMatches(server).length == 1) {
    final colon = server.indexOf(':');
    port = int.tryParse(server.substring(colon + 1));
    server = server.substring(0, colon);
    // No number after the colon: a port that is none.
    port ??= 0;
  }
  if (protocol == 'vnc' && port != null && port > 0 && port < 100) port += 5900;
  final user = found['username'];
  final domain = found['domain'];
  final group = (found['group'] ?? '').split('/').map((s) => s.trim()).where((s) => s.isNotEmpty).join(' / ');
  return CsvHostFile(rows: [
    importedHostRow(
      line: lineOfServer,
      name: found['name'] ?? server,
      host: server,
      port: port,
      user: user == null || user.isEmpty
          ? null
          : (protocol == kImportRdp && (domain ?? '').isNotEmpty && !user.contains(r'\') && !user.contains('@')
              ? '$domain\\$user'
              : user),
      group: group.isEmpty ? null : group,
      protocol: protocol,
    ),
  ]);
}
