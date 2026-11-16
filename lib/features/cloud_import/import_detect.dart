import 'dart:convert';

import 'package:zestssh/features/cloud_import/csv/csv_hosts.dart';
import 'package:zestssh/features/cloud_import/csv/other_app_hosts.dart';
import 'package:zestssh/features/cloud_import/csv/rdp_file.dart' show isRdpFile;
import 'package:zestssh/features/cloud_import/import_away.dart';
import 'package:zestssh/services/backup_service.dart';
import 'package:zestssh/services/connection_share_service.dart';
import 'package:zestssh/services/connection_share_url_service.dart' show looksLikeShareLink;

// What a file chosen to import is (picking "SSH
// config" and choosing a .zest should still import it as what it is).
// One detector, used wherever a file comes in: Import a file, and every
// importer a person picked by hand, which says so where the file is something
// else. It answers from the bytes alone and keeps nothing: a private key's
// contents go no further than its yes or no here, and nothing of a file is
// logged. Any file at all may come here, so no pattern in it may take longer
// than the file is long ([importWorkAway] keeps a large file off the screen's
// thread): test/features/cloud_import/import_hostile_test.dart times each on
// what is made to be slow, at the largest size.

/// What a file is.
enum ImportKind {
  /// A ZestSSH backup: the 'ZEST' magic ([BackupService]).
  zestBackup,

  /// A host shared from ZestSSH: a `.zest` file of plain JSON
  /// ([ConnectionShareService]).
  zestHost,

  /// An SSH config: Host or Match blocks.
  sshConfig,

  /// PuTTY's sessions exported from the Windows registry.
  puttyReg,

  /// MobaXterm's settings or sessions.
  mobaxterm,

  /// SecureCRT's settings, or one of its session files.
  secureCrt,

  /// FileZilla's Site Manager (3.4).
  fileZilla,

  /// WinSCP's sites: WinSCP.ini or its registry (3.4).
  winScp,

  /// mRemoteNG's connections file (4.0).
  mRemoteNg,

  /// One of Remmina's connection files (4.0).
  remmina,

  /// A Remote Desktop file (.rdp; 4.0). Whoever shows a file to a person
  /// calls it this only where the build offers RDP hosts (importFileOf).
  rdpFile,

  /// A private key: PEM, or PuTTY's .ppk.
  privateKey,

  /// A public key or a certificate: lines of `ssh-ed25519 AAAA...`.
  publicKey,

  /// An SSH known_hosts file.
  knownHosts,

  /// A host's share link.
  shareLink,

  /// A CSV file with a column of hosts.
  csv,

  /// None of these.
  unknown;

  /// Read by the host file import ([HostFileKind]).
  bool get isHostFile =>
      this == puttyReg ||
      this == mobaxterm ||
      this == secureCrt ||
      this == fileZilla ||
      this == winScp ||
      this == mRemoteNg ||
      this == remmina ||
      this == rdpFile ||
      this == csv;

  /// The kind of host file this is, where it is one.
  HostFileKind? get hostFile => switch (this) {
        puttyReg => HostFileKind.putty,
        mobaxterm => HostFileKind.mobaxterm,
        secureCrt => HostFileKind.securecrt,
        fileZilla => HostFileKind.filezilla,
        winScp => HostFileKind.winscp,
        mRemoteNg => HostFileKind.mremoteng,
        remmina => HostFileKind.remmina,
        rdpFile => HostFileKind.rdpfile,
        csv => HostFileKind.csv,
        _ => null,
      };
}

/// What the file [bytes] are is, as far as they go: enough of it is read to
/// tell ([kCsvMaxBytes]), a backup's first five bytes among them.
ImportKind importKindOf(List<int> bytes) => importLookAt(bytes).kind;

/// What the file [bytes] are ([importKindOf]), and for a private key whether
/// the text holds more than the key: a person may know it is something else
/// (a list with a key in a note), where nothing else may read a file that is
/// only a key.
({ImportKind kind, bool moreThanKey}) importLookAt(List<int> bytes) {
  debugImportWorkHere++;
  ({ImportKind kind, bool moreThanKey}) only(ImportKind kind) => (kind: kind, moreThanKey: false);
  if (bytes.isEmpty) return only(ImportKind.unknown);
  if (BackupService.isBackupFile(bytes)) return only(ImportKind.zestBackup);
  if (_isDerPrivateKey(bytes)) return only(ImportKind.privateKey);
  if (!importBytesAreText(bytes)) {
    // Nothing of a private key goes on to be read as anything else.
    final raw = latin1.decode(bytes);
    return only(raw.startsWith(_ssh1Key) || _privateKeyText.hasMatch(raw) ? ImportKind.privateKey : ImportKind.unknown);
  }
  if (ConnectionShareService.isShareFile(bytes)) return only(ImportKind.zestHost);
  var text = decodeCsvBytes(bytes);
  if (text.startsWith('﻿')) text = text.substring(1);
  if (text.trim().isEmpty) return only(ImportKind.unknown);
  if (text.startsWith(_ssh1Key) || text.trimLeft().startsWith('PuTTY-User-Key-File-')) return only(ImportKind.privateKey);
  // A comment naming a key's first line is not a key.
  final lines = _linesOf(text);
  if (lines.any(_privateKeyText.hasMatch)) return (kind: ImportKind.privateKey, moreThanKey: !_onlyKeys(lines));
  if (isWinScpFile(text)) return only(ImportKind.winScp);
  if (isPuttyRegFile(text)) return only(ImportKind.puttyReg);
  if (isFileZillaFile(text)) return only(ImportKind.fileZilla);
  if (isMobaXtermFile(text)) return only(ImportKind.mobaxterm);
  if (isSecureCrtFile(text)) return only(ImportKind.secureCrt);
  if (isMRemoteNgFile(text)) return only(ImportKind.mRemoteNg);
  if (isRemminaFile(text)) return only(ImportKind.remmina);
  if (isRdpFile(text)) return only(ImportKind.rdpFile);
  if (lines.isEmpty) return only(ImportKind.unknown);
  if (lines.length == 1 && looksLikeShareLink(lines.single) && !lines.single.contains(' ')) return only(ImportKind.shareLink);
  if (lines.every((l) => _keyLineFits(l) && _publicKeyLine.hasMatch(l))) return only(ImportKind.publicKey);
  // (A file of hosts' keys may have a line that was mangled by hand; it is
  // still that.)
  final hostKeys = lines.where((l) => _keyLineFits(l) && _knownHostLine.hasMatch(l)).length;
  if (hostKeys > 0 && hostKeys * 5 >= lines.length * 4) return only(ImportKind.knownHosts);
  if (_looksLikeSshConfig(lines)) return only(ImportKind.sshConfig);
  if (_looksLikeCsv(text)) return only(ImportKind.csv);
  return only(ImportKind.unknown);
}

/// Whether [bytes] can be text: UTF-16 by its byte order mark, or nothing that
/// only a binary file holds in its first part (a zero byte, or control
/// characters). A backup or an archive is not; what a wrong picker then says
/// is not the garbage it would read.
bool importBytesAreText(List<int> bytes) {
  if (bytes.length >= 2 && ((bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF))) return true;
  final end = bytes.length < 8192 ? bytes.length : 8192;
  for (var i = 0; i < end; i++) {
    final b = bytes[i];
    if (b == 0 || (b < 0x20 && b != 0x09 && b != 0x0A && b != 0x0D && b != 0x0C)) return false;
  }
  return true;
}

final _lineEnd = RegExp(r'\r\n|\r|\n');

/// The lines of [text] with anything to say, comments aside.
List<String> _linesOf(String text) => [
      for (final l in text.split(_lineEnd))
        if (l.trim().isNotEmpty && !l.trimLeft().startsWith('#')) l.trim(),
    ];

/// The one line of the share link [bytes] hold, where the detector calls them
/// one: a comment over a link is no part of it.
String? importShareLinkOf(List<int> bytes) {
  final lines = _linesOf(decodeCsvBytes(bytes));
  return lines.length == 1 && looksLikeShareLink(lines.single) ? lines.single : null;
}

/// A private key in text: PEM, as OpenSSH, OpenSSL and PGP write it, and SSH.com's
/// and SecureCRT's (`---- BEGIN SSH2 ENCRYPTED PRIVATE KEY ----`).
final _privateKeyText = RegExp(r'-{4,5} ?BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)? ?-{4,5}');

final _keyEndText = RegExp(r'-{4,5} ?END [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)? ?-{4,5}');

/// How the old SSH 1 file starts, and only starts: a note may mention it.
const _ssh1Key = 'SSH PRIVATE KEY FILE FORMAT';

final _keyBeginLine = RegExp(r'^-{4,5} ?BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)? ?-{4,5}$');
final _keyEndLine = RegExp(r'^-{4,5} ?END [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)? ?-{4,5}$');

/// Whether [lines] hold private keys and nothing else: each line between a key's
/// first and last.
bool _onlyKeys(List<String> lines) {
  var inside = false;
  for (final line in lines) {
    if (inside) {
      if (_keyEndLine.hasMatch(line)) inside = false;
    } else if (_keyBeginLine.hasMatch(line)) {
      inside = true;
    } else {
      return false;
    }
  }
  return true;
}

/// The text [bytes], which hold a private key and more besides ([importLookAt]),
/// without the key: what a person who says it is something else has read, so
/// that none of the key is read as hosts, listed or put in a field. Each line
/// stays a line, empty where the key was, so a line's number is still its number
/// and a cell around a key still closes. A key with no last line runs to the end
/// of the text. Comment lines stay, as when it is looked at: one only names a key.
List<int> importWithoutKeys(List<int> bytes) {
  debugImportWorkHere++;
  var text = decodeCsvBytes(bytes);
  if (text.startsWith('\uFEFF')) text = text.substring(1);
  final out = <String>[];
  var inside = false;
  for (final line in text.split(_lineEnd)) {
    if (!inside && line.trimLeft().startsWith('#')) {
      out.add(line);
      continue;
    }
    final kept = StringBuffer();
    var at = 0;
    while (true) {
      if (inside) {
        final end = _keyEndText.allMatches(line, at).firstOrNull;
        if (end == null) break;
        at = end.end;
        inside = false;
      } else {
        final begin = _privateKeyText.allMatches(line, at).firstOrNull;
        if (begin == null) {
          kept.write(line.substring(at));
          break;
        }
        kept.write(line.substring(at, begin.start));
        at = begin.end;
        inside = true;
      }
    }
    out.add(kept.toString());
  }
  return utf8.encode(out.join('\n'));
}

/// A private key in DER: a SEQUENCE that starts with a version, then what each
/// form has next: PKCS#1 (version 0 and the modulus), PKCS#8 (version 0 or 1 and
/// the algorithm), SEC1 (version 1 and the key), a PKCS#12 file (version 3 and
/// what it holds); or an encrypted PKCS#8, which starts with how it is encrypted
/// (PBES2, or one of PKCS#12's).
bool _isDerPrivateKey(List<int> b) {
  int? afterHeader(int at) {
    if (at + 2 > b.length) return null;
    final first = b[at + 1];
    if (first < 0x80) return at + 2;
    final more = first & 0x7f;
    return more == 0 || more > 4 ? null : at + 2 + more;
  }

  if (b.isEmpty || b[0] != 0x30) return false;
  final i = afterHeader(0);
  if (i == null || i + 4 > b.length) return false;
  if (b[i] == 0x02 && b[i + 1] == 0x01) {
    final version = b[i + 2], next = b[i + 3];
    return (version == 0 && (next == 0x02 || next == 0x30)) ||
        (version == 1 && (next == 0x04 || next == 0x30)) ||
        (version == 3 && next == 0x30);
  }
  if (b[i] != 0x30) return false;
  final j = afterHeader(i);
  if (j == null || j + 11 > b.length || b[j] != 0x06) return false;
  const pkcs = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01];
  for (var k = 0; k < pkcs.length; k++) {
    if (b[j + 2 + k] != pkcs[k]) return false;
  }
  return (b[j + 9] == 0x05 && b[j + 10] == 0x0d) || b[j + 9] == 0x0c;
}

/// No line of a public key or known_hosts file is anywhere near this long: a
/// longer one is not looked at as one.
const _maxKeyLine = 64 * 1024;

bool _keyLineFits(String line) => line.length <= _maxKeyLine;

const _keyTypes = r'(?:ssh-(?:ed25519|rsa|dss)|ecdsa-sha2-nistp(?:256|384|521)|sk-ssh-ed25519@openssh\.com|'
    r'sk-ecdsa-sha2-nistp256@openssh\.com|ssh-(?:ed25519|rsa|dss)-cert-v01@openssh\.com|'
    r'ecdsa-sha2-nistp(?:256|384|521)-cert-v01@openssh\.com)';

/// One of an authorized_keys line's options, as sshd knows them (a word alone
/// would be a host's name in a known_hosts line), its value in double quotes
/// where it has one. The value is written as one unbroken run between escapes,
/// and the option as a word from a list, so that there is one way to read any
/// text: no pattern here may try two.
const _keyOption = '(?:agent-forwarding|cert-authority|command|environment|expiry-time|from|no-agent-forwarding|'
    'no-port-forwarding|no-pty|no-touch-required|no-user-rc|no-x11-forwarding|permitlisten|permitopen|port-forwarding|'
    'principals|pty|restrict|tunnel|user-rc|verify-required|x11-forwarding)(?:="[^"\\\\]*(?:\\\\.[^"\\\\]*)*")?';

/// `ssh-ed25519 AAAA... comment`, or the same with an authorized_keys line's
/// options before it (`from="10.0.0.1",no-pty ssh-ed25519 AAAA...`).
final _publicKeyLine =
    RegExp('^(?:$_keyOption(?:,$_keyOption)*\\s+)?$_keyTypes\\s+AAAA\\S+(?:\\s.*)?\$', caseSensitive: false);

/// `host,other ssh-ed25519 AAAA...`, a marker before it where there is one, or
/// the names hashed (`|1|salt|hash`).
final _knownHostLine = RegExp('^(?:@\\S+\\s+)?(?:\\|1\\|\\S+|[^\\s="]+)\\s+$_keyTypes\\s+AAAA\\S+(?:\\s.*)?\$');

/// The first word of a line of an SSH config, in small letters: what follows
/// a Host line in a real one.
const _sshOptions = {
  'addkeystoagent', 'batchmode', 'canonicalizehostname', 'certificatefile', 'ciphers', 'compression', 'connecttimeout',
  'controlmaster', 'controlpath', 'controlpersist', 'dynamicforward', 'forwardagent', 'forwardx11', 'gssapiauthentication',
  'hashknownhosts', 'host', 'hostkeyalgorithms', 'hostname', 'identitiesonly', 'identityfile', 'include', 'kexalgorithms',
  'localforward', 'loglevel', 'macs', 'match', 'passwordauthentication', 'pkcs11provider', 'port', 'preferredauthentications',
  'proxycommand', 'proxyjump', 'pubkeyacceptedalgorithms', 'pubkeyacceptedkeytypes', 'remotecommand', 'remoteforward',
  'requesttty', 'sendenv', 'serveralivecountmax', 'serveraliveinterval', 'setenv', 'stricthostkeychecking', 'tcpkeepalive',
  'usekeychain', 'user', 'userknownhostsfile', 'visualhostkey', 'xauthlocation',
};

final _configLine = RegExp(r'^([A-Za-z][A-Za-z0-9]*)(?:\s*=\s*|\s+)(\S.*)$');

/// No line of an SSH config is anywhere near this long: a longer one is not looked at as one.
/// (Dart 3.14's patterns keep less to go back over: a Host followed by megabytes of spaces
/// and no end ran out of it, "Stack Overflow", where Dart 3.10 said no match.)
bool _configLineFits(String line) => line.length <= _maxKeyLine;

/// A Host or Match line with options after it, or at the very end. A CSV file's
/// first line ("Host Name,Address") is no Host line: a config's names have no
/// commas, semicolons or tabs between them.
bool _looksLikeSshConfig(List<String> lines) {
  for (var i = 0; i < lines.length; i++) {
    final m = _configLineFits(lines[i]) ? _configLine.firstMatch(lines[i]) : null;
    if (m == null) continue;
    final word = m.group(1)!.toLowerCase();
    if (word != 'host' && word != 'match') continue;
    if (RegExp('[,;\t]').hasMatch(m.group(2)!) && word == 'host') continue;
    if (i + 1 == lines.length) return true;
    final next = _configLineFits(lines[i + 1]) ? _configLine.firstMatch(lines[i + 1]) : null;
    if (next != null && _sshOptions.contains(next.group(1)!.toLowerCase())) return true;
  }
  return false;
}

/// A first line naming a column of hosts ([readCsvHosts], which is left to
/// read it all later).
bool _looksLikeCsv(String text) {
  final end = text.indexOf(_lineEnd);
  final first = end < 0 ? text : text.substring(0, end);
  if (first.length > 4096) return false;
  return readCsvHosts(first).problem == null;
}
