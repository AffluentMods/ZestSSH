import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/keys/authorized_keys_edit.dart';
import 'package:zestssh/features/run/install_key.dart';
import 'package:zestssh/services/key_generation_service.dart';

/// Taking a key off an authorized_keys file (Replace on all hosts, 3.0):
/// only the old key's own lines, matched by the key's bytes, never by a
/// piece of a comment or of another key; every other line kept to the byte;
/// nothing taken out where the old key has options or a line holding it
/// cannot be read. And the checksum the write is guarded with is POSIX
/// cksum's (checked against cksum itself where WSL is there).
void main() {
  late String oldLine;
  late String newLine;
  late String otherLine;
  late Uint8List oldBlob;
  late Uint8List newBlob;

  setUpAll(() async {
    final gen = KeyGenerationService();
    oldLine = (await gen.generateEd25519(comment: 'old@laptop')).publicOpenSSH.trim();
    newLine = (await gen.generateEd25519(comment: 'new@laptop')).publicOpenSSH.trim();
    otherLine = (await gen.generateEd25519(comment: 'someone else')).publicOpenSSH.trim();
    oldBlob = blobOfPublicLine(oldLine)!;
    newBlob = blobOfPublicLine(newLine)!;
  });

  Uint8List bytes(String s) => Uint8List.fromList(latin1.encode(s));
  String text(Uint8List b) => latin1.decode(b);
  String keyOf(String line) => line.split(' ')[1];

  test('the old key line goes with its line end; every other line, comment and blank stays to the byte', () {
    final file = '# keys of ops\n$otherLine\n\n$oldLine\n   \n$newLine\n';
    final r = removeKeyLines(bytes(file), oldBlob, keep: newBlob);
    expect(r.removed, [4]);
    expect(r.refused, isFalse);
    expect(r.keepsNewKey, isTrue);
    expect(text(r.bytes), '# keys of ops\n$otherLine\n\n   \n$newLine\n');
  });

  test('CRLF line ends, a last line without one, and bytes that are no UTF-8 stay as they were', () {
    final file = Uint8List.fromList([
      ...latin1.encode('$otherLine caf\xe9\r\n'),
      ...latin1.encode('$oldLine\r\n'),
      ...latin1.encode(newLine),
    ]);
    final r = removeKeyLines(file, oldBlob, keep: newBlob);
    expect(r.removed, [2]);
    expect(r.bytes, [...latin1.encode('$otherLine caf\xe9\r\n'), ...latin1.encode(newLine)]);
  });

  test('every copy of the old key goes, whatever its comment, its padding or the spaces before it', () {
    final unpadded = keyOf(oldLine).replaceAll('=', '');
    final file = '$oldLine\n  ssh-ed25519 $unpadded a comment\n\tssh-ed25519 ${keyOf(oldLine)}\n$newLine\n';
    final r = removeKeyLines(bytes(file), oldBlob, keep: newBlob);
    expect(r.removed, [1, 2, 3]);
    expect(text(r.bytes), '$newLine\n');
  });

  test('the old key in a comment, or in another line\'s comment, is not the old key: nothing is taken out', () {
    final file = '# was: $oldLine\n$otherLine ${keyOf(oldLine)}\n$newLine\n';
    final r = removeKeyLines(bytes(file), oldBlob, keep: newBlob);
    expect(r.removed, isEmpty);
    expect(r.refused, isFalse);
    expect(text(r.bytes), file);
  });

  test('a wrong old key never takes anything out', () {
    final file = '$otherLine\n$newLine\n';
    final r = removeKeyLines(bytes(file), oldBlob, keep: newBlob);
    expect(r.removed, isEmpty);
    expect(r.bytes, bytes(file));
  });

  test('the old key with options is left, and nothing is taken out (the person changes it)', () {
    for (final options in ['from="10.0.0.0/8"', 'no-pty,no-agent-forwarding', 'command="echo \\"hi there\\"",restrict', 'cert-authority']) {
      final file = '$options $oldLine\n$oldLine\n$newLine\n';
      final r = removeKeyLines(bytes(file), oldBlob, keep: newBlob);
      expect(r.withOptions, [1], reason: options);
      expect(r.removed, isEmpty, reason: options);
      expect(text(r.bytes), file, reason: options);
    }
  });

  test('another key with options is kept as it is', () {
    final file = 'from="10.0.0.1",no-pty $otherLine\n$oldLine\n$newLine\n';
    final r = removeKeyLines(bytes(file), oldBlob, keep: newBlob);
    expect(r.removed, [2]);
    expect(text(r.bytes), 'from="10.0.0.1",no-pty $otherLine\n$newLine\n');
  });

  test('a line that cannot be read but holds the old key: nothing is taken out', () {
    final file = 'command="unclosed ${keyOf(oldLine)}\n$oldLine\n$newLine\n';
    final r = removeKeyLines(bytes(file), oldBlob, keep: newBlob);
    expect(r.unreadable, [1]);
    expect(r.removed, isEmpty);
    expect(text(r.bytes), file);
  });

  test('whether the new key is left in the file is said', () {
    final r = removeKeyLines(bytes('$oldLine\n$otherLine\n'), oldBlob, keep: newBlob);
    expect(r.keepsNewKey, isFalse);
  });

  test('a line is read as sshd reads it', () {
    expect(readAuthorizedKeysLine('# x', 1).blob, isNull);
    expect(readAuthorizedKeysLine('', 1).unreadable, isFalse);
    final plain = readAuthorizedKeysLine(oldLine, 1);
    expect(plain.blob, oldBlob);
    expect(plain.options, isNull);
    final withOptions = readAuthorizedKeysLine('environment="A=b c",from="x" $oldLine', 2);
    expect(withOptions.options, 'environment="A=b c",from="x"');
    expect(withOptions.blob, oldBlob);
    expect(readAuthorizedKeysLine('garbage', 3).unreadable, isTrue);
    expect(readAuthorizedKeysLine('ssh-ed25519 not*base64', 3).unreadable, isTrue);
  });

  test('POSIX cksum: the known values', () {
    // As GNU coreutils' cksum (POSIX mode) prints them.
    expect(posixCksum(const []), '4294967295 0');
    expect(posixCksum(latin1.encode('a')), '1220704766 1');
    expect(posixCksum(latin1.encode('123456789')), '930766865 9');
  });

  test("what the read command prints is read: a shell's own start-up text before it is skipped, a file cut short is refused", () {
    final file = bytes('$oldLine\n$newLine\n');
    final said = Uint8List.fromList([
      ...latin1.encode('Welcome!\n$kAkSum ${posixCksum(file)}\n$kAkBegin\n'),
      ...file,
    ]);
    final read = readAuthorizedKeysOutput(said);
    expect(read, isA<AuthorizedKeysFile>());
    expect((read! as AuthorizedKeysFile).bytes, file);
    expect(readAuthorizedKeysOutput(Uint8List.fromList(said.sublist(0, said.length - 3))), isNull);
    expect(readAuthorizedKeysOutput(bytes('$kAkNone\n')), isA<AuthorizedKeysMissing>());
    expect(readAuthorizedKeysOutput(bytes('$kAkLink\n')), isA<AuthorizedKeysIsLink>());
    expect(readAuthorizedKeysOutput(bytes('nothing\n')), isNull);
  });

  test("the add step is Install on hosts' own command, for the file given", () {
    expect(installKeyCommandFor(), kInstallKeyCommand);
    final other = installKeyCommandFor('/tmp/x/authorized_keys');
    expect(other, kInstallKeyCommand.replaceFirst('f=.ssh/authorized_keys;', 'f=/tmp/x/authorized_keys;'));
    expect(() => writeAuthorizedKeysCommand('not a sum'), throwsArgumentError);
    expect(isPlainPath("a'b"), isFalse);
    expect(isPlainPath('../x'), isFalse);
  });

  test('cksum here is what cksum says (WSL)', () async {
    ProcessResult r;
    try {
      r = await Process.run('wsl', ['-d', 'Ubuntu', '-e', 'sh', '-c', 'printf "%s" "\$1" | cksum', 'sh', 'ssh-ed25519 AAAA x\n\xff'],
          stdoutEncoding: latin1);
    } catch (_) {
      return markTestSkipped('WSL is not available');
    }
    if (r.exitCode != 0) return markTestSkipped('WSL is not available');
    expect('${r.stdout}'.trim(), posixCksum(utf8.encode('ssh-ed25519 AAAA x\n\xff')));
  });
}
