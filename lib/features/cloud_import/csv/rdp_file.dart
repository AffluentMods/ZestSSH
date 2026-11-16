// Importing hosts (4.0): a Remote Desktop file (.rdp), as Windows'
// own client and others save one connection. Each line is `name:type:value`
// (type s for text, i for a number, b for bytes). What an RDP host of this
// app can hold is read; the rest is counted and left.
//
// Never read: the saved password (`password 51`, bytes tied to the Windows
// account that saved them, of no use anywhere else and nothing an import
// should carry about). Never obeyed: a file that names a program to start,
// or that turns Network Level Authentication off. Such a file's host comes in
// as a whole desktop with NLA on, and the import says so.
import 'package:zestssh/features/cloud_import/cloud_machine.dart' show cleanCloudText;
import 'package:zestssh/features/cloud_import/csv/csv_hosts.dart';

/// What is wrong with a .rdp file as a whole.
enum RdpFileProblem {
  /// It is larger than [kCsvMaxBytes].
  tooLarge,

  /// It names no computer (`full address`), or what it names is no address.
  noAddress,
}

/// One connection read from a .rdp file.
class RdpFile {
  const RdpFile({
    this.address = '',
    this.port = 3389,
    this.user,
    this.domain,
    this.gateway,
    this.gatewayPort = 443,
    this.gatewaySameSignIn = true,
    this.allMonitors = false,
    this.monitors = 1,
    this.sound,
    this.clipboard,
    this.hadPassword = false,
    this.forProgram = false,
    this.nlaOff = false,
    this.unused = 0,
    this.problem,
  });

  /// The computer's address, without its port; empty with [problem].
  final String address;
  final int port;

  /// The account as the file has it (`user`, `DOMAIN\user` or
  /// `user@domain`), and the domain where the file names one apart.
  final String? user;
  final String? domain;

  /// The RD Gateway the file says to go through, where it says to use one;
  /// null where it names none or says not to.
  final String? gateway;
  final int gatewayPort;

  /// The gateway is signed in to with the computer's account.
  final bool gatewaySameSignIn;

  /// The file asks for every monitor of the device ([monitors] then counts
  /// the ones it picked, 0 where it picked none in particular).
  final bool allMonitors;
  final int monitors;

  /// The remote's sound played on this device (true), not at all or on the
  /// remote (false); null where the file does not say.
  final bool? sound;

  /// The clipboard shared (true) or not (false); null where it does not say.
  final bool? clipboard;

  /// The file held a saved password. It was not read.
  final bool hadPassword;

  /// The file was for one program on the remote, not its desktop. The
  /// program is not kept: the host opens the desktop.
  final bool forProgram;

  /// The file turned Network Level Authentication off. The host keeps it on.
  final bool nlaOff;

  /// Lines with a setting this version has no use for.
  final int unused;
  final RdpFileProblem? problem;

  /// The account's name as an RDP host's key takes it: with the domain in
  /// front where the file names one apart and the name carries none.
  String? get account {
    final u = user;
    if (u == null || u.isEmpty) return null;
    final d = domain;
    if (d == null || d.isEmpty || u.contains(r'\') || u.contains('@')) return u;
    return '$d\\$u';
  }
}

/// The most lines of a .rdp file that are looked at (Windows writes about
/// fifty).
const kRdpFileMaxLines = 2000;

final _name = RegExp(r'^[A-Za-z0-9 _\-]{1,64}$');

/// A line's setting and value (`name:type:value`, the type one of s, i and
/// b); null for any other line. Read by hand, a character at a time: a
/// pattern for the whole line went back over a line of spaces sixty-four
/// times for each of them, and a file of such lines took seconds.
({String name, String value})? _settingOf(String line) {
  final colon = line.indexOf(':');
  if (colon < 1 || colon + 2 >= line.length || line.codeUnitAt(colon + 2) != 0x3a) return null;
  if (!'sibSIB'.contains(line[colon + 1])) return null;
  final name = line.substring(0, colon).trim();
  if (!_name.hasMatch(name)) return null;
  return (name: name.toLowerCase(), value: line.substring(colon + 3));
}

/// Whether [text] is a .rdp file: it has a `full address` line.
bool isRdpFile(String text) {
  final head = text.length > 65536 ? text.substring(0, 65536) : text;
  return RegExp(r'^[ \t]*full address:s:', multiLine: true, caseSensitive: false).hasMatch(head);
}

/// An address and the port written into it ("pc.example.com:3390",
/// "[2001:db8::1]:3389"); null where it is no address (empty, too long, with
/// a space, a slash or an account in it, or a leading dash).
({String host, int? port})? _addressOf(String raw) {
  var s = raw.trim();
  int? port;
  if (s.startsWith('[')) {
    final close = s.indexOf(']');
    if (close < 0) return null;
    final rest = s.substring(close + 1);
    s = s.substring(1, close);
    if (rest.isNotEmpty) {
      if (!rest.startsWith(':')) return null;
      port = int.tryParse(rest.substring(1));
      if (port == null) return null;
    }
  } else if (':'.allMatches(s).length == 1) {
    final colon = s.indexOf(':');
    port = int.tryParse(s.substring(colon + 1));
    if (port == null) return null;
    s = s.substring(0, colon);
  }
  if (importAddressIsNone(s)) return null;
  if (port != null && (port < 1 || port > 65535)) return null;
  return (host: s, port: port);
}

/// The connection a .rdp file's [text] holds.
RdpFile readRdpFile(String text) {
  if (text.length > kCsvMaxBytes) return const RdpFile(problem: RdpFileProblem.tooLarge);
  // A byte order mark left in the text.
  if (text.startsWith(String.fromCharCode(0xFEFF))) text = text.substring(1);
  final values = <String, String>{};
  var unused = 0;
  var lines = 0;
  var start = 0;
  // A line at a time, without splitting the whole text first: a hostile file
  // of one long line, or of millions of short ones, costs what is looked at.
  while (start < text.length && lines < kRdpFileMaxLines) {
    var end = text.indexOf('\n', start);
    if (end < 0) end = text.length;
    var line = text.substring(start, end);
    start = end + 1;
    lines++;
    if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
    if (line.length > 4096) line = line.substring(0, 4096);
    final setting = _settingOf(line);
    if (setting == null) continue;
    final key = setting.name;
    // The first of a name counts: a file that says a thing twice is not
    // followed to its last word. A saved password is noted as there and
    // not kept, even for as long as the file is read.
    if (!values.containsKey(key)) values[key] = key.startsWith('password') ? '' : setting.value;
    if (!_used.contains(key)) unused++;
  }

  String? textOf(String key, {int max = 255}) {
    final raw = values[key];
    if (raw == null) return null;
    final clean = cleanCloudText(raw, max: max);
    return clean.isEmpty ? null : clean;
  }

  int? numberOf(String key) {
    final raw = values[key]?.trim();
    if (raw == null || raw.length > 10) return null;
    return int.tryParse(raw);
  }

  final address = _addressOf(values['full address'] ?? '');
  if (address == null) return RdpFile(problem: RdpFileProblem.noAddress, unused: unused);
  final serverPort = numberOf('server port');
  final port = address.port ?? (serverPort != null && serverPort >= 1 && serverPort <= 65535 ? serverPort : 3389);

  // A gateway only where the file says to use one (1: always, 2: where the
  // computer is not reached directly).
  final usage = numberOf('gatewayusagemethod');
  final gatewayAt = usage == 1 || usage == 2 ? _addressOf(values['gatewayhostname'] ?? '') : null;

  final selected = (values['selectedmonitors'] ?? '')
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty && int.tryParse(s) != null)
      .toSet()
      .length;
  final multimon = numberOf('use multimon') == 1;

  final program = numberOf('remoteapplicationmode') == 1 ||
      (values['remoteapplicationprogram'] ?? '').trim().isNotEmpty ||
      (values['alternate shell'] ?? '').trim().isNotEmpty;

  return RdpFile(
    address: address.host,
    port: port,
    user: textOf('username'),
    domain: textOf('domain', max: 64),
    gateway: gatewayAt?.host,
    gatewayPort: gatewayAt?.port ?? 443,
    // 0: the gateway asks for its own sign-in; anything else, or nothing
    // said, with "ask once" on: the computer's.
    gatewaySameSignIn: numberOf('promptcredentialonce') != 0,
    allMonitors: multimon,
    monitors: multimon ? selected : 1,
    sound: switch (numberOf('audiomode')) { 0 => true, 1 || 2 => false, _ => null },
    clipboard: switch (numberOf('redirectclipboard')) { 1 => true, 0 => false, _ => null },
    hadPassword: values.keys.any((k) => k.startsWith('password')),
    forProgram: program,
    nlaOff: numberOf('enablecredsspsupport') == 0,
    unused: unused,
  );
}

/// The settings this version reads, or knows and leaves on purpose (the
/// password, a program to start): the rest are counted as unused.
const _used = {
  'full address',
  'server port',
  'username',
  'domain',
  'gatewayhostname',
  'gatewayusagemethod',
  'promptcredentialonce',
  'use multimon',
  'selectedmonitors',
  'audiomode',
  'redirectclipboard',
  'enablecredsspsupport',
  'password 51',
  'remoteapplicationmode',
  'remoteapplicationprogram',
  'alternate shell',
};

/// The host a .rdp file's [text] holds, as the host file import takes one:
/// nothing where this build offers no RDP hosts ([rdp]). What the file asked
/// for and is not followed (a saved password, one program, NLA off, an RD
/// Gateway) is said in [CsvHostFile.notes]. The host is named after the file
/// ([fileName], "Office PC.rdp"), or after its address where the file has no
/// name of its own (pasted text, Windows' own Default.rdp).
CsvHostFile readRdpFileHosts(String text, {bool rdp = false, String? fileName}) {
  if (text.length > kCsvMaxBytes) return const CsvHostFile(problem: CsvFileProblem.tooLarge);
  if (!rdp) return const CsvHostFile(problem: CsvFileProblem.empty);
  final file = readRdpFile(text);
  if (file.problem == RdpFileProblem.tooLarge) return const CsvHostFile(problem: CsvFileProblem.tooLarge);
  final picked = file.allMonitors && file.monitors > 1 ? file.monitors : 1;
  return CsvHostFile(
    rows: [
      // (No address: a row that says so, as any host file's line without one.)
      importedHostRow(
        line: 1,
        name: _nameOfFile(fileName) ?? file.address,
        host: file.address,
        port: file.port,
        user: file.account,
        protocol: kImportRdp,
        clipboardOff: file.clipboard == false,
        displays: picked > 4 ? 4 : picked,
        gateway: file.gateway,
        gatewayPort: file.gatewayPort,
      ),
    ],
    notes: [
      if (file.hadPassword) HostFileNote.rdpPassword,
      if (file.forProgram) HostFileNote.rdpProgram,
      if (file.nlaOff) HostFileNote.rdpNlaOff,
      if (file.gateway != null) HostFileNote.rdpGateway,
    ],
    gateway: file.gateway,
  );
}

/// A host's name from its .rdp file's: without the ending, and none for a
/// name that says nothing (Default.rdp, which Windows keeps for itself) or
/// that is no .rdp file's (a pasted text has the import's own word for it).
String? _nameOfFile(String? fileName) {
  if (fileName == null) return null;
  final trimmed = fileName.trim();
  if (!trimmed.toLowerCase().endsWith('.rdp')) return null;
  final name = cleanCloudText(trimmed.substring(0, trimmed.length - 4), max: 255);
  return name.isEmpty || name.toLowerCase() == 'default' ? null : name;
}
