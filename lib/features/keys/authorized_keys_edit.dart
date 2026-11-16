import 'dart:convert';
import 'dart:typed_data';

import 'package:zestssh/features/run/install_key.dart';

// Taking a key off a host (3.0, Replace on all hosts):
// the one risky step of replacing a key, the old
// key's line removed from the account's authorized_keys. What is read and
// written on the host is plain sh (POSIX), and what the file becomes is
// worked out here, in Dart, byte for byte ([removeKeyLines]), so it can be
// tested line by line:
//
// * only a line whose key is the old key's, compared as the key's bytes
//   (never a piece of a comment or of another key) and that has no options,
//   is taken out, with its line end; every other line stays as it was, to
//   the byte;
// * a line that holds the old key with options (from=, command=, restrict,
//   a certificate authority's line) is never touched, and is said, nor is a
//   line that cannot be read but holds the old key's text;
// * the file is read with its checksum (POSIX cksum) and written only where
//   it is still the file that was read, through a file of its own beside it
//   that has the file's permissions (cp -p), moved over it in one step;
// * nothing is written where the new key is not in what would be left.

/// Where the authorized keys of the account a host is signed in to as are,
/// from its home folder: where OpenSSH looks by default.
const kAuthorizedKeysFile = '.ssh/authorized_keys';

/// Whether [path] can be put into the commands below as it is (no quote, no
/// space, nothing a shell reads as more than a path).
bool isPlainPath(String path) => RegExp(r'^[A-Za-z0-9_./-]+$').hasMatch(path) && !path.contains('..');

/// What [readAuthorizedKeysCommand] prints first.
const kAkNone = 'ZESTSSH_AK_NONE';
const kAkLink = 'ZESTSSH_AK_LINK';
const kAkSum = 'ZESTSSH_AK_SUM';
const kAkBegin = 'ZESTSSH_AK_BEGIN';
const kAkChanged = 'ZESTSSH_AK_CHANGED';
const kAkWritten = 'ZESTSSH_AK_WRITTEN';

/// The command that prints the account's authorized keys file [path]: that
/// there is none ([kAkNone]), that it is a link ([kAkLink], never written
/// through), or its checksum ([kAkSum] and `cksum`'s two numbers), a line
/// [kAkBegin] and then the file, byte for byte.
String readAuthorizedKeysCommand([String path = kAuthorizedKeysFile]) {
  assert(isPlainPath(path));
  return "exec sh -c 'cd || exit 5; f=$path; "
      r'if [ -L "$f" ]; then echo ZESTSSH_AK_LINK; exit 0; fi; '
      r'if [ ! -f "$f" ]; then echo ZESTSSH_AK_NONE; exit 0; fi; '
      r'printf "ZESTSSH_AK_SUM %s\n" "$(cksum < "$f")" || exit 6; echo ZESTSSH_AK_BEGIN; exec cat "$f"'
      "'";
}

/// The command that writes what it reads (its standard input) over the
/// authorized keys file [path], where that is still the file whose `cksum`
/// was [expectedSum] (else it says [kAkChanged] and writes nothing): into a
/// file of its own beside it that is a copy of it, its permissions too
/// (`cp -p`), then moved over it. It says [kAkWritten] and the checksum of
/// what is there now.
String writeAuthorizedKeysCommand(String expectedSum, [String path = kAuthorizedKeysFile]) {
  assert(isPlainPath(path));
  if (!RegExp(r'^[0-9]+ [0-9]+$').hasMatch(expectedSum)) {
    throw ArgumentError.value(expectedSum, 'expectedSum', 'not a checksum');
  }
  return "exec sh -c 'umask 077; cd || exit 5; f=$path; "
      r'if [ -L "$f" ] || [ ! -f "$f" ]; then exit 8; fi; '
      'if [ "\$(cksum < "\$f")" != "$expectedSum" ]; then echo ZESTSSH_AK_CHANGED; exit 0; fi; '
      r't="$f.zestssh-$$"; rm -f "$t"; cp -p "$f" "$t" || exit 9; '
      r'if ! cat > "$t"; then rm -f "$t"; exit 9; fi; '
      r'if ! mv -f "$t" "$f"; then rm -f "$t"; exit 9; fi; '
      r'if command -v restorecon >/dev/null 2>&1; then restorecon -F "$f" >/dev/null 2>&1; fi; '
      r'printf "ZESTSSH_AK_WRITTEN %s\n" "$(cksum < "$f")"'
      "'";
}

/// [kInstallKeyCommand] (Install on hosts: ssh-copy-id's steps) for the
/// authorized keys file [path].
String installKeyCommandFor([String path = kAuthorizedKeysFile]) {
  assert(isPlainPath(path));
  const at = 'f=$kAuthorizedKeysFile;';
  if (!kInstallKeyCommand.contains(at)) throw StateError('The install command no longer names its file');
  return path == kAuthorizedKeysFile ? kInstallKeyCommand : kInstallKeyCommand.replaceFirst(at, 'f=$path;');
}

/// POSIX `cksum` of [bytes] as it prints it: the CRC and the length.
String posixCksum(List<int> bytes) {
  var crc = 0;
  void add(int byte) {
    crc ^= byte << 24;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 0x80000000) != 0 ? ((crc << 1) ^ 0x04C11DB7) : (crc << 1);
      crc &= 0xFFFFFFFF;
    }
  }

  for (final b in bytes) {
    add(b);
  }
  for (var n = bytes.length; n > 0; n >>= 8) {
    add(n & 0xFF);
  }
  return '${(~crc) & 0xFFFFFFFF} ${bytes.length}';
}

/// What [readAuthorizedKeysCommand] printed, read.
sealed class AuthorizedKeysRead {
  const AuthorizedKeysRead();
}

/// There is no file: no key in it to take off.
class AuthorizedKeysMissing extends AuthorizedKeysRead {
  const AuthorizedKeysMissing();
}

/// The file is a link: never written through.
class AuthorizedKeysIsLink extends AuthorizedKeysRead {
  const AuthorizedKeysIsLink();
}

/// The file, and its checksum as the host gave it.
class AuthorizedKeysFile extends AuthorizedKeysRead {
  const AuthorizedKeysFile(this.bytes, this.sum);

  final Uint8List bytes;
  final String sum;
}

/// [output], what [readAuthorizedKeysCommand] printed (a shell's start-up
/// files may print before it), read; null where it is not what the command
/// prints, or the file came through other than it is (its checksum does not
/// match what came).
AuthorizedKeysRead? readAuthorizedKeysOutput(Uint8List output) {
  final text = latin1.decode(output);
  for (final (marker, read) in [(kAkNone, const AuthorizedKeysMissing()), (kAkLink, const AuthorizedKeysIsLink())]) {
    if (RegExp('(^|\\n)$marker\\n').hasMatch(text) && !text.contains('$kAkSum ')) return read;
  }
  final sum = RegExp('(^|\\n)$kAkSum ([0-9]+ [0-9]+)\\n$kAkBegin\\n').firstMatch(text);
  if (sum == null) return null;
  final bytes = Uint8List.fromList(output.sublist(sum.end));
  final said = sum.group(2)!;
  return posixCksum(bytes) == said ? AuthorizedKeysFile(bytes, said) : null;
}

/// The key types a line of authorized_keys may start with (sshd(8)).
final _keyType = RegExp(
    r'^(ssh-(ed25519|ed448|rsa|dss)|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com|[a-z0-9.-]+-cert-v01@openssh\.com)$');

/// One line of authorized_keys, read.
class AuthorizedKeysLine {
  const AuthorizedKeysLine({required this.number, this.blob, this.options, this.unreadable = false});

  /// Its place in the file, from 1.
  final int number;

  /// Its key's bytes, where it has a key that can be read.
  final Uint8List? blob;

  /// Its options, where it has some (`from="10.0.0.0/8",no-pty`).
  final String? options;

  /// It is not a comment or blank and could not be read as a key line.
  final bool unreadable;
}

/// [line] (without its line end) read as sshd reads it: blank or a comment
/// (no key), a key type and its key, or options, then a key type and its key.
AuthorizedKeysLine readAuthorizedKeysLine(String line, int number) {
  var rest = line.replaceFirst(RegExp(r'^[ \t]+'), '');
  if (rest.isEmpty || rest.startsWith('#')) return AuthorizedKeysLine(number: number);
  String? options;
  final first = rest.split(RegExp(r'[ \t]'))[0];
  if (!_keyType.hasMatch(first)) {
    // Options: up to the first space or tab outside double quotes; inside
    // them a backslash keeps the quote after it.
    var quoted = false;
    var end = -1;
    for (var i = 0; i < rest.length; i++) {
      final c = rest[i];
      if (quoted && c == r'\' && i + 1 < rest.length && rest[i + 1] == '"') {
        i++;
      } else if (c == '"') {
        quoted = !quoted;
      } else if (!quoted && (c == ' ' || c == '\t')) {
        end = i;
        break;
      }
    }
    if (quoted || end < 0) return AuthorizedKeysLine(number: number, unreadable: true);
    options = rest.substring(0, end);
    rest = rest.substring(end).replaceFirst(RegExp(r'^[ \t]+'), '');
  }
  final parts = rest.split(RegExp(r'[ \t]+'));
  if (parts.length < 2 || !_keyType.hasMatch(parts[0])) return AuthorizedKeysLine(number: number, unreadable: true);
  final blob = blobOf(parts[1]);
  if (blob == null) return AuthorizedKeysLine(number: number, unreadable: true);
  return AuthorizedKeysLine(number: number, blob: blob, options: options);
}

/// The bytes of [base64Key], a key as a public key line writes it (with
/// base64's padding or without); null where it is not base64.
Uint8List? blobOf(String base64Key) {
  final text = base64Key.trim();
  if (text.isEmpty || !RegExp(r'^[A-Za-z0-9+/]+=*$').hasMatch(text)) return null;
  try {
    return base64.decode(base64.normalize(text));
  } catch (_) {
    return null;
  }
}

/// The key bytes of [publicLine] ("ssh-ed25519 AAAA... comment"); null where
/// it is not a public key line.
Uint8List? blobOfPublicLine(String? publicLine) {
  final parts = (publicLine ?? '').trim().split(RegExp(r'\s+'));
  return parts.length < 2 ? null : blobOf(parts[1]);
}

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// What taking a key off an authorized_keys file comes to.
class AuthorizedKeysRemoval {
  const AuthorizedKeysRemoval({
    required this.bytes,
    required this.removed,
    required this.withOptions,
    required this.unreadable,
    required this.keepsNewKey,
  });

  /// The file without the key's lines (as it was where none is taken out).
  final Uint8List bytes;

  /// The lines taken out (their numbers in the file as it was).
  final List<int> removed;

  /// Lines that hold the key with options: left as they are.
  final List<int> withOptions;

  /// Lines that could not be read and hold the key's text: left as they are.
  final List<int> unreadable;

  /// Whether the file left holds the new key ([removeKeyLines]'s `keep`).
  final bool keepsNewKey;

  /// Whether a line holds the key that is not taken out: then nothing is.
  bool get refused => withOptions.isNotEmpty || unreadable.isNotEmpty;
}

/// [file] (an authorized_keys file, as bytes) without each line whose key is
/// [old], and with every other line, its line end too, as it was. Where a
/// line holds [old] with options, or holds its text and cannot be read,
/// nothing is taken out ([AuthorizedKeysRemoval.refused]): a key with
/// options is the person's to change. [keep], the new key, is looked for in
/// what is left ([AuthorizedKeysRemoval.keepsNewKey]).
AuthorizedKeysRemoval removeKeyLines(Uint8List file, Uint8List old, {Uint8List? keep}) {
  final oldText = base64.encode(old).replaceAll('=', '');
  final out = BytesBuilder(copy: false);
  final removed = <int>[];
  final withOptions = <int>[];
  final unreadable = <int>[];
  var keepsNewKey = false;
  var start = 0;
  var number = 0;
  final kept = <List<int>>[];
  while (start < file.length) {
    number++;
    var end = file.indexOf(0x0A, start);
    end = end < 0 ? file.length : end + 1;
    final raw = Uint8List.sublistView(file, start, end);
    start = end;
    var content = latin1.decode(raw);
    if (content.endsWith('\n')) content = content.substring(0, content.length - 1);
    if (content.endsWith('\r')) content = content.substring(0, content.length - 1);
    final line = readAuthorizedKeysLine(content, number);
    final blob = line.blob;
    if (blob != null && _same(blob, old)) {
      if (line.options != null) {
        withOptions.add(number);
        kept.add(raw);
      } else {
        removed.add(number);
      }
      continue;
    }
    if (line.unreadable && content.contains(oldText)) unreadable.add(number);
    if (blob != null && keep != null && _same(blob, keep)) keepsNewKey = true;
    kept.add(raw);
  }
  final refused = withOptions.isNotEmpty || unreadable.isNotEmpty;
  if (refused) {
    out.add(file);
  } else {
    for (final raw in kept) {
      out.add(raw);
    }
  }
  return AuthorizedKeysRemoval(
    bytes: out.takeBytes(),
    removed: refused ? const [] : removed,
    withOptions: withOptions,
    unreadable: unreadable,
    keepsNewKey: keepsNewKey,
  );
}
