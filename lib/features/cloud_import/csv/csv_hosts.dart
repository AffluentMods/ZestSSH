/// Hosts from a CSV file (3.0; importing hosts
/// from a spreadsheet): a file whose first line names its columns,
/// read as a spreadsheet writes it, each line a host. Columns are known by
/// their names in any order and case ([kCsvHostColumns]); others are left
/// out and said so. Nothing in a file is trusted: every field is cleaned and
/// bounded as a cloud's are, and a line that names no host, or a port or a
/// way of connecting that is none, is said with why and not imported.
library;

import 'dart:convert';

import 'package:zestssh/database/daos/connection_tags_dao.dart';
import 'package:zestssh/features/screens/model/screen_options.dart' show ScreenGateway;
import 'package:zestssh/features/cloud_import/cloud_machine.dart' show cleanCloudText;

/// The largest file read.
const kCsvMaxBytes = 5 * 1024 * 1024;

/// The most hosts read from one file.
const kCsvMaxHosts = 5000;

/// A column a host file may have.
enum CsvHostColumn { name, host, port, user, group, tags, key, protocol, note }

/// The names each column goes by: compared without case, spaces, dashes or
/// underscores ("IP Address" is `ipaddress`).
const kCsvHostColumns = <CsvHostColumn, List<String>>{
  CsvHostColumn.name: ['name', 'label', 'title', 'alias', 'hostname alias', 'display name'],
  CsvHostColumn.host: ['host', 'hostname', 'address', 'ip', 'ip address', 'server', 'host address'],
  CsvHostColumn.port: ['port', 'ssh port'],
  CsvHostColumn.user: ['user', 'username', 'user name', 'login'],
  // (Groups, KeyLabel: termius-export's hosts.csv, Termius's own template.)
  CsvHostColumn.group: ['group', 'groups', 'folder', 'group name'],
  CsvHostColumn.tags: ['tags', 'tag', 'labels'],
  CsvHostColumn.key: ['key', 'identity', 'ssh key', 'key name', 'key label'],
  CsvHostColumn.protocol: ['protocol', 'type'],
  CsvHostColumn.note: ['note', 'notes', 'description', 'comment', 'comments'],
};

/// The ways of connecting a host may be imported as (a host's `protocol`, as
/// stored). A file may also name FTP or FTPS ([ftpsImportOf]): those come in as
/// FTPS, explicit or implicit, never as plain FTP.
const kCsvProtocols = {'ssh', 'sftp', 'mosh', 'et', 'telnet', 'ftps', 'ftpsImplicit', 'vnc'};

/// A remote screen over RDP (4.0): imported only where this build offers RDP
/// hosts at all (rdpOfferedProvider), which each reader is told.
const kImportRdp = 'rdp';

/// Whether [protocol], as an import stores it, is a remote screen (VNC or RDP).
bool csvIsScreen(String protocol) => protocol == 'vnc' || protocol == kImportRdp;

/// The ways of connecting an import takes: [kCsvProtocols], and RDP where
/// this build offers it ([rdp]).
bool importTakes(String protocol, {required bool rdp}) =>
    kCsvProtocols.contains(protocol) || (rdp && protocol == kImportRdp);

/// The port a host has where a file names none: its protocol's own.
int importDefaultPort(String protocol) => switch (protocol) {
      'vnc' => 5900,
      kImportRdp => 3389,
      'telnet' => 23,
      _ => csvIsFtps(protocol) ? ftpsDefaultPort(protocol) : 22,
    };

/// The port an FTPS host has where a file names none: 21 for explicit TLS,
/// 990 for implicit.
int ftpsDefaultPort(String protocol) => protocol == 'ftpsImplicit' ? 990 : 21;

/// What a file's way of connecting [name] is as an FTPS host, where it is FTP
/// or FTPS of any kind (imports turn FTP rows into
/// FTPS hosts; plain FTP never): plain FTP and explicit FTPS (FTPES, FTP over
/// TLS) as explicit TLS, FTPS as implicit TLS; on [port] 990, implicit's own,
/// always implicit, and FTPS on 21, explicit's, explicit. [wasPlain] says the
/// file had it as plain FTP. Null for anything else.
({String protocol, bool wasPlain})? ftpsImportOf(String name, {int? port}) {
  final n = name.toLowerCase().replaceAll(RegExp(r'[\s_\-/+()]+'), '');
  const plain = {'ftp', 'insecureftp', 'plainftp'};
  const explicit = {
    'ftpes', 'ftpexplicit', 'explicitftp', 'ftpsexplicit', 'explicitftps', 'ftptls', 'ftpssl', 'ftpovertls', //
    'ftpoverssl', 'ftpsexplicittls', 'explicittls',
  };
  const implicit = {'ftpsimplicit', 'implicitftps', 'ftpimplicit', 'implicitftp', 'ftpsimplicittls', 'implicittls'};
  final String protocol;
  var wasPlain = false;
  if (plain.contains(n)) {
    wasPlain = true;
    protocol = 'ftps';
  } else if (explicit.contains(n)) {
    protocol = 'ftps';
  } else if (implicit.contains(n)) {
    protocol = 'ftpsImplicit';
  } else if (n == 'ftps') {
    protocol = port == 21 ? 'ftps' : 'ftpsImplicit';
  } else {
    return null;
  }
  if (port == 990) return (protocol: 'ftpsImplicit', wasPlain: wasPlain);
  return (protocol: protocol, wasPlain: wasPlain);
}

/// Whether [protocol], as an import stores it, is FTPS.
bool csvIsFtps(String protocol) => protocol == 'ftps' || protocol == 'ftpsImplicit';

/// What is wrong with one line of a host file.
enum CsvRowProblem {
  /// It names no host.
  noHost,

  /// What it names as the host is no address.
  badHost,

  /// Its port is no number from 1 to 65535.
  badPort,

  /// Its way of connecting is none of [kCsvProtocols].
  badProtocol,
}

/// What is wrong with a host file as a whole.
enum CsvFileProblem {
  /// It holds no line with anything in it.
  empty,

  /// None of its columns is a host's address.
  noHostColumn,

  /// It is larger than [kCsvMaxBytes].
  tooLarge,
}

/// Something a host file asked for that the import did not follow, said
/// beside its hosts before anything is imported.
enum HostFileNote {
  /// A Remote Desktop file held a saved password. It was not read.
  rdpPassword,

  /// A Remote Desktop file was for one program; the host opens the desktop.
  rdpProgram,

  /// A Remote Desktop file turned Network Level Authentication off; the
  /// host keeps it on.
  rdpNlaOff,

  /// A Remote Desktop file goes through an RD Gateway ([CsvHostFile.gateway]),
  /// which this version cannot; the host connects directly.
  rdpGateway,
}

/// One host of a file: the line it is on (the first line is 1), what it
/// says, and what is wrong with it where something is.
class CsvHostRow {
  const CsvHostRow({
    required this.line,
    required this.name,
    required this.host,
    this.port = 22,
    this.user,
    this.group,
    this.tags = const [],
    this.key,
    this.protocol = 'ssh',
    this.note,
    this.problem,
    this.wasPlainFtp = false,
    this.clipboardOff = false,
    this.displays = 1,
    this.gateway,
    this.gatewayPort = 443,
  });

  final int line;
  final String name;
  final String host;
  final int port;
  final String? user;
  final String? group;
  final List<String> tags;

  /// The name of a key this device has, to sign in with.
  final String? key;
  final String protocol;
  final String? note;
  final CsvRowProblem? problem;

  /// The file had this host as plain FTP; it comes in as FTPS ([ftpsImportOf]).
  final bool wasPlainFtp;

  /// A remote screen whose file said not to share the clipboard: the host
  /// comes in with its clipboard off. (A file that says to share it changes
  /// nothing: the host has the default every new one has.)
  final bool clipboardOff;

  /// A Remote Desktop host: how many displays its file picked, 1 where it
  /// picked none in particular.
  final int displays;

  /// A Remote Desktop host whose file goes through an RD Gateway (4.0, step
  /// 4): its address and port, an address [ScreenGateway.hostOk] takes. It
  /// comes into the host's options only where the build offers gateways
  /// ([CsvImportTarget.rdpGateway]); else the host connects directly, and the
  /// import says so ([HostFileNote.rdpGateway]).
  final String? gateway;
  final int gatewayPort;

  /// Whether it comes in as an FTPS host.
  bool get isFtps => csvIsFtps(protocol);
}

/// A host file read: its hosts, which column each known one is, the columns
/// left out (by their names in the file), and whether more hosts came than
/// are read ([kCsvMaxHosts]).
class CsvHostFile {
  const CsvHostFile({
    this.rows = const [],
    this.columns = const {},
    this.ignored = const [],
    this.cut = false,
    this.problem,
    this.notes = const [],
    this.gateway,
  });

  final List<CsvHostRow> rows;
  final Map<CsvHostColumn, int> columns;
  final List<String> ignored;
  final bool cut;
  final CsvFileProblem? problem;

  /// What the file asked for and the import did not follow.
  final List<HostFileNote> notes;

  /// The RD Gateway of [HostFileNote.rdpGateway], as the file has it.
  final String? gateway;
}

/// The text of a file's [bytes]: UTF-16 where they start with its byte order
/// mark (a spreadsheet's "Unicode text"), else UTF-8, else Latin-1 (a
/// spreadsheet that writes in its own code page).
String decodeCsvBytes(List<int> bytes) {
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) return _utf16(bytes, little: true);
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) return _utf16(bytes, little: false);
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return latin1.decode(bytes);
  }
}

/// [bytes] after their byte order mark, as UTF-16 code units.
String _utf16(List<int> bytes, {required bool little}) {
  final units = <int>[
    for (var i = 2; i + 1 < bytes.length; i += 2) little ? bytes[i] | bytes[i + 1] << 8 : bytes[i] << 8 | bytes[i + 1],
  ];
  return String.fromCharCodes(units);
}

/// [header] as a column's name is compared.
String _columnKey(String header) => header.toLowerCase().replaceAll(RegExp(r'[\s_\-]+'), '');

/// The delimiter of a file whose first line is [header]: a comma, a
/// semicolon or a tab, whichever splits it most outside quotes; a comma where
/// none does.
String csvDelimiterOf(String header) {
  final counts = {',': 0, ';': 0, '\t': 0};
  var quoted = false;
  for (final c in header.split('')) {
    if (c == '"') quoted = !quoted;
    if (!quoted && counts.containsKey(c)) counts[c] = counts[c]! + 1;
  }
  var best = ',';
  for (final d in const [';', '\t']) {
    if (counts[d]! > counts[best]!) best = d;
  }
  return best;
}

/// The lines of [text], each as its fields, split by [delimiter] as a
/// spreadsheet writes them: a field in double quotes may hold the delimiter,
/// line ends, and `""` for a quote. Lines with nothing in them are left out.
List<List<String>> parseCsvLines(String text, String delimiter) {
  final lines = <List<String>>[];
  var fields = <String>[];
  final field = StringBuffer();
  var quoted = false;
  var wasQuoted = false;

  void endField() {
    fields.add(field.toString());
    field.clear();
    wasQuoted = false;
  }

  void endLine() {
    endField();
    if (fields.any((f) => f.trim().isNotEmpty)) lines.add(fields);
    fields = <String>[];
  }

  var i = 0;
  while (i < text.length) {
    final c = text[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i += 2;
          continue;
        }
        quoted = false;
      } else {
        field.write(c);
      }
      i++;
      continue;
    }
    if (c == '"' && field.isEmpty && !wasQuoted) {
      quoted = true;
      wasQuoted = true;
    } else if (c == delimiter) {
      endField();
    } else if (c == '\r') {
      if (i + 1 < text.length && text[i + 1] == '\n') i++;
      endLine();
    } else if (c == '\n') {
      endLine();
    } else {
      field.write(c);
    }
    i++;
  }
  if (field.isNotEmpty || fields.isNotEmpty || wasQuoted) endLine();
  return lines;
}

// (With the marks that hide or reorder text beside them: a zero-width or a
// right-to-left override in an address makes it read as another address
// wherever it is shown, the question about a server's key among them. And
// with what no name or address of a computer has in it and something that
// is handed one later may read as its own: an account's at sign, a
// shell's and a link's punctuation, an entity an XML file left unread.)
final _noAddress = RegExp(r'''[\s\u0000-\u001f\u007f-\u009f\u200b-\u200f\u202a-\u202e\u2060-\u2064\u2066-\u2069\ufeff/\\@;&|$`'"<>(){}*?!#=,^~]''');

/// Whether [host] is no address: too long, with what none has in it, or a
/// leading dash, which reads as an option (-oProxyCommand) wherever it is
/// passed later.
bool _isNoAddress(String host) => host.length > 253 || _noAddress.hasMatch(host) || host.startsWith('-');

/// Whether [host], as a file from elsewhere has it, is no address an import
/// takes: for a reader that shows or keeps an address of its own (a Remote
/// Desktop file's gateway) beside the hosts [importedHostRow] checks.
bool importAddressIsNone(String host) => host.isEmpty || _isNoAddress(host);

/// [raw] (a field of a host column) split into an address, and the user and
/// port written into it ("deploy@web-01.example.com:2222", "[2001:db8::1]:22"),
/// where there are.
({String host, String? user, int? port, bool badPort}) _addressOf(String raw) {
  var s = raw.trim();
  String? user;
  int? port;
  var badPort = false;
  final at = s.lastIndexOf('@');
  if (at > 0) {
    user = s.substring(0, at);
    s = s.substring(at + 1);
  }
  if (s.startsWith('[')) {
    final close = s.indexOf(']');
    if (close > 0) {
      final rest = s.substring(close + 1);
      s = s.substring(1, close);
      if (rest.startsWith(':')) {
        port = int.tryParse(rest.substring(1));
        badPort = port == null || port < 1 || port > 65535;
      }
    }
  } else if (':'.allMatches(s).length == 1) {
    final colon = s.indexOf(':');
    port = int.tryParse(s.substring(colon + 1));
    badPort = port == null || port < 1 || port > 65535;
    s = s.substring(0, colon);
  }
  return (host: s, user: user, port: port, badPort: badPort);
}

/// The hosts of [text], a CSV file whose first line names its columns.
CsvHostFile readCsvHosts(String text, {bool rdp = false}) {
  if (text.length > kCsvMaxBytes) return const CsvHostFile(problem: CsvFileProblem.tooLarge);
  if (text.startsWith('\uFEFF')) text = text.substring(1);
  final firstEnd = text.indexOf(RegExp(r'[\r\n]'));
  final header = firstEnd < 0 ? text : text.substring(0, firstEnd);
  final lines = parseCsvLines(text, csvDelimiterOf(header));
  if (lines.isEmpty) return const CsvHostFile(problem: CsvFileProblem.empty);

  final columns = <CsvHostColumn, int>{};
  final ignored = <String>[];
  final names = {
    for (final e in kCsvHostColumns.entries)
      for (final n in e.value) _columnKey(n): e.key,
  };
  for (var i = 0; i < lines.first.length; i++) {
    final title = cleanCloudText(lines.first[i], max: 64);
    final column = names[_columnKey(title)];
    if (column != null && !columns.containsKey(column)) {
      columns[column] = i;
    } else if (title.isNotEmpty) {
      ignored.add(title);
    }
  }
  if (!columns.containsKey(CsvHostColumn.host)) {
    return CsvHostFile(columns: columns, ignored: ignored, problem: CsvFileProblem.noHostColumn);
  }

  String field(List<String> fields, CsvHostColumn column) {
    final at = columns[column];
    return at == null || at >= fields.length ? '' : fields[at];
  }

  String? text0(String raw, int max) {
    final s = cleanCloudText(raw, max: max);
    return s.isEmpty ? null : s;
  }

  final rows = <CsvHostRow>[];
  final data = lines.skip(1).toList();
  for (var i = 0; i < data.length && rows.length < kCsvMaxHosts; i++) {
    final fields = data[i];
    final address = _addressOf(field(fields, CsvHostColumn.host));
    CsvRowProblem? problem;
    var host = address.host;
    if (host.isEmpty) {
      problem = CsvRowProblem.noHost;
    } else if (_isNoAddress(host)) {
      problem = CsvRowProblem.badHost;
      host = cleanCloudText(host, max: 253);
    }
    final portText = field(fields, CsvHostColumn.port).trim();
    final protocolText = field(fields, CsvHostColumn.protocol).trim();
    final ftps = ftpsImportOf(protocolText, port: portText.isEmpty ? address.port : int.tryParse(portText));
    final named = protocolText.toLowerCase();
    // A screen's own port where the file names none; every other line as before.
    var port = address.port ??
        (ftps != null ? ftpsDefaultPort(ftps.protocol) : (csvIsScreen(named) ? importDefaultPort(named) : 22));
    if (portText.isNotEmpty) {
      final p = int.tryParse(portText);
      if (p == null || p < 1 || p > 65535) {
        problem ??= CsvRowProblem.badPort;
      } else {
        port = p;
      }
    } else if (address.badPort) {
      problem ??= CsvRowProblem.badPort;
    }
    final protocol = ftps?.protocol ?? (protocolText.isEmpty ? 'ssh' : named);
    if (!importTakes(protocol, rdp: rdp)) problem ??= CsvRowProblem.badProtocol;
    final tags = <String>[];
    for (final t in field(fields, CsvHostColumn.tags).split(RegExp(r'[;|,]'))) {
      final tag = ConnectionTagsDao.normalize(t);
      if (tag != null && !tags.contains(tag) && tags.length < 12) tags.add(tag);
    }
    rows.add(CsvHostRow(
      line: i + 2,
      name: text0(field(fields, CsvHostColumn.name), 255) ?? (host.isEmpty ? '' : cleanCloudText(host, max: 255)),
      host: host,
      port: port,
      user: text0(field(fields, CsvHostColumn.user), 255) ?? (address.user == null ? null : text0(address.user!, 255)),
      group: text0(field(fields, CsvHostColumn.group), 255),
      tags: tags,
      key: text0(field(fields, CsvHostColumn.key), 255),
      protocol: importTakes(protocol, rdp: rdp) ? protocol : 'ssh',
      note: text0(field(fields, CsvHostColumn.note), 4096),
      problem: problem,
      wasPlainFtp: ftps?.wasPlain ?? false,
    ));
  }
  return CsvHostFile(rows: rows, columns: columns, ignored: ignored, cut: data.length > rows.length);
}

/// A host read from another app's file (MobaXterm, SecureCRT, FileZilla,
/// WinSCP), checked as a CSV line is: no host, a host that is no address, a
/// port out of range. An FTPS host with no port has its TLS's own
/// ([ftpsDefaultPort]).
CsvHostRow importedHostRow({
  required int line,
  required String name,
  required String host,
  int? port,
  String? user,
  String? group,
  String protocol = 'ssh',
  bool wasPlainFtp = false,
  bool clipboardOff = false,
  int displays = 1,
  String? gateway,
  int gatewayPort = 443,
}) {
  String? text0(String? raw, int max) {
    if (raw == null) return null;
    final s = cleanCloudText(raw, max: max);
    return s.isEmpty ? null : s;
  }

  var h = host.trim();
  CsvRowProblem? problem;
  if (h.isEmpty) {
    problem = CsvRowProblem.noHost;
  } else if (_isNoAddress(h)) {
    problem = CsvRowProblem.badHost;
    h = cleanCloudText(h, max: 253);
  }
  // (A reader hands an RDP host here only where this build offers RDP.)
  final known = importTakes(protocol, rdp: true) ? protocol : 'ssh';
  // As before for every kind there was: 22 unless FTPS; a screen's own port.
  final fallback = csvIsFtps(known) ? ftpsDefaultPort(known) : (csvIsScreen(known) ? importDefaultPort(known) : 22);
  final p = port ?? fallback;
  if (p < 1 || p > 65535) problem ??= CsvRowProblem.badPort;
  return CsvHostRow(
    line: line,
    name: text0(name, 255) ?? (h.isEmpty ? '' : cleanCloudText(h, max: 255)),
    host: h,
    port: p < 1 || p > 65535 ? fallback : p,
    user: text0(user, 255),
    group: text0(group, 255),
    protocol: known,
    problem: problem,
    wasPlainFtp: wasPlainFtp && csvIsFtps(known),
    clipboardOff: clipboardOff && csvIsScreen(known),
    displays: known == kImportRdp && displays > 1 ? displays : 1,
    gateway: known == kImportRdp && ScreenGateway.hostOk(gateway) && gatewayPort >= 1 && gatewayPort <= 65535 ? gateway : null,
    gatewayPort: gatewayPort,
  );
}

/// What an import does with one host of a file.
enum CsvRowStatus {
  /// Added.
  fresh,

  /// A host with its address and port is here already: left out.
  here,

  /// A line before it in the file names the same address and port.
  twice,

  /// Something is wrong with it ([CsvHostRow.problem]): left out.
  problem,
}

/// [row] as an import would take it: new, here already (a host in [existing]
/// with its address, in any case, and port), named twice in the file, or a
/// line with a problem. An FTPS host goes into a team as into a person's own
/// space (3.4). [seen] gathers the addresses read so far.
CsvRowStatus csvRowStatus(CsvHostRow row, Set<String> existing, Set<String> seen) {
  if (row.problem != null) return CsvRowStatus.problem;
  final where = csvAddressKey(row.host, row.port);
  if (existing.contains(where)) return CsvRowStatus.here;
  if (!seen.add(where)) return CsvRowStatus.twice;
  return CsvRowStatus.fresh;
}

/// A host's address and port as an import compares them.
String csvAddressKey(String host, int port) => '${host.toLowerCase()}:$port';
