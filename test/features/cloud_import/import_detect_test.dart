import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/cloud_import/csv/csv_hosts.dart';
import 'package:zestssh/features/cloud_import/csv/other_app_hosts.dart';
import 'package:zestssh/features/cloud_import/import_detect.dart';
import 'package:zestssh/features/cloud_import/ui/import_file.dart' show importCanReadAnyway, importCanTake, importFileOf;
import 'package:zestssh/services/backup_service.dart';

/// What a file chosen to import is (a .zest chosen under "SSH
/// config" should be detected from the file itself):
/// one fixture for each kind, and what would be mistaken for one.

List<int> _utf16(String text) => [0xFF, 0xFE, for (final c in text.codeUnits) ...[c & 0xFF, c >> 8]];

const _sshConfig = '''
# My servers
Host web1
  HostName 203.0.113.10
  User deploy
  Port 2222

Host db
  HostName db.example.com
  IdentityFile ~/.ssh/id_ed25519
''';

const _mobaXterm = r'''
[Misc]
Something=1
[Bookmarks]
SubRep=Production
ImgNum=42
web1=#109#0%203.0.113.10%22%deploy%%-1%-1%
''';

const _secureCrtXml = '<?xml version="1.0"?>\n<VanDyke version="3.0"><key name="Sessions"></key></VanDyke>\n';
const _secureCrtIni = 'S:"Protocol Name"=SSH2\nS:"Hostname"=203.0.113.11\nD:"[SSH2] Port"=00000016\nS:"Username"=deploy\n';

const _puttyReg = r'''
Windows Registry Editor Version 5.00

[HKEY_CURRENT_USER\Software\SimonTatham\PuTTY\Sessions\Default%20Settings]
"PortNumber"=dword:00000016

[HKEY_CURRENT_USER\Software\SimonTatham\PuTTY\Sessions\web%201]
"HostName"="web1.example.com"
"PortNumber"=dword:000008ae
"UserName"="deploy"
"Protocol"="ssh"

[HKEY_CURRENT_USER\Software\SimonTatham\PuTTY\Sessions\switch]
"HostName"="admin@192.0.2.1"
"Protocol"="telnet"
"PortNumber"=dword:00000017

[HKEY_CURRENT_USER\Software\SimonTatham\PuTTY\Sessions\console]
"HostName"="COM1"
"Protocol"="serial"

[HKEY_CURRENT_USER\Software\SimonTatham\PuTTY\SshHostKeys]
"ssh-ed25519@22:example.com"="0x1,0x2"
''';

// (Made up: the shape of a key, no key.)
const _opensshPrivate = '-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----\n';
const _rsaPrivate = '-----BEGIN RSA PRIVATE KEY-----\nMIIEow==\n-----END RSA PRIVATE KEY-----\n';
const _ppk = 'PuTTY-User-Key-File-3: ssh-ed25519\nEncryption: none\nComment: demo\nPublic-Lines: 2\nAAAA\nAAAA\n';
const _publicKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDemoDemoDemoDemoDemoDemoDemoDemoDemoDemoDemo demo@example.com\n';
const _authorizedKeys = 'from="192.0.2.0/24" ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDemo demo@example.com\n'
    'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDemo\n';
const _cert = 'ssh-ed25519-cert-v01@openssh.com AAAAIHNzaC1lZDI1NTE5LWNlcnQtdjAxDemo demo@example.com\n';
const _knownHosts = 'web1.example.com,203.0.113.10 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDemo\n'
    '[db.example.com]:2222 ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYDemo\n'
    '|1|F1E1KeoE/eEWhi10WpGv4OdiO6Y=|3988QV0VE8wmZL7suNrYQLITLCg= ssh-rsa AAAAB3NzaC1yc2EAAAABIwDemo\n'
    '@revoked old.example.com ssh-rsa AAAAB3NzaC1yc2EAAAABIwDemo\n';
const _shareLink = 'zestssh://add-host?host=web1.example.com&port=22&user=deploy&label=Web\n';
const _csv = 'Name,Host,Port,User\nWeb,203.0.113.10,22,deploy\n';
const _csvSemicolons = 'name;ip address;user\nWeb;203.0.113.10;deploy\n';

void main() {
  ImportKind of(String text) => importKindOf(utf8.encode(text));

  group('one fixture for each kind', () {
    test('a ZestSSH backup, by its magic', () {
      expect(importKindOf([0x5a, 0x45, 0x53, 0x54, 3, 0xff, 0x00, 0x01]), ImportKind.zestBackup);
      expect(importKindOf([...utf8.encode('ZEST'), 2, ...utf8.encode('{"a":1}')]), ImportKind.zestBackup);
    });

    test('a host shared as a .zest file, in the clear or sealed', () {
      expect(of(jsonEncode({'type': 'zestssh_connection', 'host': 'web1.example.com'})), ImportKind.zestHost);
      expect(of(jsonEncode({'type': 'zestssh_connection_encrypted', 'data': 'abc'})), ImportKind.zestHost);
    });

    test('an SSH config: Host blocks, and Match blocks', () {
      expect(of(_sshConfig), ImportKind.sshConfig);
      expect(of('Match host *.example.com\n  User deploy\n'), ImportKind.sshConfig);
      expect(of('host=web1\nhostname=203.0.113.10\n'), ImportKind.sshConfig);
      expect(of('Host web1\n'), ImportKind.sshConfig, reason: 'a Host alone at the end of a file');
    });

    test('PuTTY\'s sessions from the registry, as regedit writes them too (UTF-16)', () {
      expect(of(_puttyReg), ImportKind.puttyReg);
      expect(importKindOf(_utf16(_puttyReg)), ImportKind.puttyReg);
      expect(of('REGEDIT4\n\n[HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\Sessions\\x]\n'), ImportKind.puttyReg);
    });

    test('MobaXterm', () => expect(of(_mobaXterm), ImportKind.mobaxterm));

    test('SecureCRT: its settings, and a session file', () {
      expect(of(_secureCrtXml), ImportKind.secureCrt);
      expect(of(_secureCrtIni), ImportKind.secureCrt);
    });

    test('a private key: PEM of every kind, and PuTTY\'s .ppk', () {
      expect(of(_opensshPrivate), ImportKind.privateKey);
      expect(of(_rsaPrivate), ImportKind.privateKey);
      expect(of('-----BEGIN EC PRIVATE KEY-----\nx\n-----END EC PRIVATE KEY-----\n'), ImportKind.privateKey);
      expect(of('-----BEGIN ENCRYPTED PRIVATE KEY-----\nx\n-----END ENCRYPTED PRIVATE KEY-----\n'), ImportKind.privateKey);
      expect(of(_ppk), ImportKind.privateKey);
    });

    test('a public key: a line, an authorized_keys, a certificate', () {
      expect(of(_publicKey), ImportKind.publicKey);
      expect(of(_authorizedKeys), ImportKind.publicKey);
      expect(of(_cert), ImportKind.publicKey);
      expect(of('# my key\n$_publicKey\n'), ImportKind.publicKey);
    });

    test('known_hosts: names, hashed names, markers', () {
      expect(of(_knownHosts), ImportKind.knownHosts);
      expect(of('# from my laptop\n$_knownHosts'), ImportKind.knownHosts);
    });

    test('a share link, of either kind', () {
      expect(of(_shareLink), ImportKind.shareLink);
      expect(of('zestssh://share?d=eyJ2IjoxfQ\n'), ImportKind.shareLink);
    });

    test('a CSV file with a column of hosts, in any spreadsheet\'s dress', () {
      expect(of(_csv), ImportKind.csv);
      expect(of(_csvSemicolons), ImportKind.csv);
      expect(of('﻿$_csv'), ImportKind.csv);
      expect(importKindOf(_utf16(_csv)), ImportKind.csv);
      expect(of('Host Name,Address\nWeb,203.0.113.10\n'), ImportKind.csv, reason: 'Host is no Host block');
      expect(of('Host Name\nweb1\nweb2\n'), ImportKind.csv, reason: 'one word on each line after it is no config');
      expect(of('Hostname\tPort\nweb1\t22\n'), ImportKind.csv);
    });
  });

  group('what it could not tell', () {
    test('nothing, a picture, a zip, words, JSON that is nothing of ours', () {
      expect(importKindOf(const []), ImportKind.unknown);
      expect(of('   \n\n'), ImportKind.unknown);
      expect(importKindOf([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13]), ImportKind.unknown);
      expect(importKindOf([0x50, 0x4b, 0x03, 0x04, 0x14, 0, 0, 0, 8, 0]), ImportKind.unknown);
      expect(of('Dear team,\nplease find attached the list.\n'), ImportKind.unknown);
      expect(of('{"hosts": ["a", "b"]}'), ImportKind.unknown);
      expect(of('web1\nweb2\nweb3\n'), ImportKind.unknown, reason: 'no column of hosts');
      expect(of('zestssh://share?d=abc and more words'), ImportKind.unknown);
    });
  });

  group('what stands between kinds', () {
    test('a file with a private key in it is a private key, whatever else it looks like', () {
      expect(of('Host web1\n  HostName example.com\n$_opensshPrivate'), ImportKind.privateKey);
    });

    test('a config\'s keys are named, not held: it stays a config', () {
      expect(of('Host web1\n  IdentityFile ~/.ssh/id_rsa\n'), ImportKind.sshConfig);
    });

    test('MobaXterm in a large settings file, with its bookmarks far down', () {
      expect(of('${'[Misc]\nA=1\n' * 2000}[Bookmarks]\nSubRep=\n'), ImportKind.mobaxterm);
    });

    test('known_hosts with a line someone broke by hand is still that; a config is not', () {
      expect(of('$_knownHosts\nnot a line of it\n'), ImportKind.knownHosts);
      expect(of('Host web1 ssh-ed25519 AAAAC3Nza\n  HostName example.com\n'), isNot(ImportKind.unknown));
    });
  });

  group('a file of hosts\' keys and a file of a person\'s keys are told apart', () {
    const hashed = '|1|F1E1KeoE/eEWhi10WpGv4OdiO6Y=|3988QV0VE8wmZL7suNrYQLITLCg= ssh-rsa AAAAB3NzaC1yc2EAAAABIwDemo\n'
        '|1|Ab1Cd2Ef3Gh4Ij5Kl6Mn7Op8Qr9=|St0Uv1Wx2Yz3Ab4Cd5Ef6Gh7Ij8= ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDemo\n';

    test('known_hosts with every name hashed is that (it was called a public key)', () {
      expect(of(hashed), ImportKind.knownHosts);
      expect(of('# hashed by ssh-keygen -H\n$hashed'), ImportKind.knownHosts);
    });

    test('one name before a key is a host, whatever it is called', () {
      expect(of('localhost ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDemo\n'), ImportKind.knownHosts);
      expect(of('web-01 ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYDemo comment\n'), ImportKind.knownHosts);
      expect(of('203.0.113.10 ssh-rsa AAAAB3NzaC1yc2EAAAABIwDemo\n'), ImportKind.knownHosts);
    });

    test('what sshd knows before a key is an option: alone, in a list, with a value in quotes', () {
      for (final options in [
        'no-pty',
        'restrict,pty',
        'from="192.0.2.0/24"',
        'command="/usr/bin/backup --all",no-agent-forwarding',
        r'command="echo \"hello, there\"",no-pty',
        'environment="A=b c",from="*.example.com,!bad.example.com"',
        'cert-authority,principals="deploy"',
        'PTY',
      ]) {
        expect(of('$options ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDemo demo@example.com\n'), ImportKind.publicKey, reason: options);
      }
    });

    test('nothing else stands before a key, and a key is more than its type', () {
      expect(of('nosuchoption="x" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDemo\n'), ImportKind.unknown);
      expect(of('from="never closed ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDemo\n'), ImportKind.unknown);
      expect(of('ssh-ed25519 BBBBC3Nza\n'), ImportKind.unknown);
    });
  });

  group('a private key in any form says so, and nothing of it is read as anything else', () {
    test('as text: SSH.com\'s and SecureCRT\'s, PGP\'s, the old SSH 1 file', () {
      for (final key in [
        '---- BEGIN SSH2 ENCRYPTED PRIVATE KEY ----\nComment: "demo"\nP2/56wAAAAA=\n---- END SSH2 ENCRYPTED PRIVATE KEY ----\n',
        '---- BEGIN SSH2 PRIVATE KEY ----\nP2/56wAAAAA=\n---- END SSH2 PRIVATE KEY ----\n',
        '-----BEGIN PGP PRIVATE KEY BLOCK-----\nlQOYBF==\n-----END PGP PRIVATE KEY BLOCK-----\n',
        '-----BEGIN DSA PRIVATE KEY-----\nMIIBug==\n-----END DSA PRIVATE KEY-----\n',
        'SSH PRIVATE KEY FILE FORMAT 1.1\n',
        // Under other lines, which would read as a config.
        'Host web1\n  HostName example.com\n---- BEGIN SSH2 PRIVATE KEY ----\nP2/56wAAAAA=\n',
      ]) {
        expect(of(key), ImportKind.privateKey, reason: key);
        expect(importKindOf(_utf16(key)), ImportKind.privateKey, reason: 'in UTF-16: $key');
        expect(importFileOf(name: 'k', bytes: utf8.encode(key)).bytes, isNull, reason: 'not kept');
      }
    });

    /// [body] in a DER SEQUENCE, its length as long as it needs.
    List<int> der(List<int> body) => [
          0x30,
          if (body.length < 0x80) body.length else ...[0x82, body.length >> 8, body.length & 0xff],
          ...body,
        ];
    final filler = List.filled(400, 0x41);

    test('in DER: PKCS#1, PKCS#8, SEC1, an encrypted PKCS#8, and the old SSH 1 file', () {
      final keys = {
        'PKCS#1': der([0x02, 0x01, 0x00, 0x02, 0x82, 0x01, 0x01, ...filler]),
        'PKCS#8': der([0x02, 0x01, 0x00, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x04, 0x82, ...filler]),
        'PKCS#8 version 1': der([0x02, 0x01, 0x01, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, ...filler]),
        'SEC1': der([0x02, 0x01, 0x01, 0x04, 0x20, ...filler]),
        'PBES2': der([0x30, 0x57, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x05, 0x0d, ...filler]),
        'PKCS#12 PBE': der([0x30, 0x1c, 0x06, 0x0a, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x0c, 0x01, 0x03, ...filler]),
        'SSH 1': [...latin1.encode('SSH PRIVATE KEY FILE FORMAT 1.1\n'), 0, 0, 0, 0, ...filler],
        'PKCS#12': der([0x02, 0x01, 0x03, 0x30, 0x82, 0x04, 0x80, 0x06, 0x09, 0x2a, ...filler]),
      };
      keys.forEach((name, bytes) {
        expect(importKindOf(bytes), ImportKind.privateKey, reason: name);
        expect(importFileOf(name: 'k', bytes: bytes).bytes, isNull, reason: 'not kept: $name');
      });
    });

    test('what starts like one and holds nothing secret is not: a certificate, public keys, CSV', () {
      expect(of('---- BEGIN SSH2 PUBLIC KEY ----\nAAAAB3Nza\n---- END SSH2 PUBLIC KEY ----\n'), isNot(ImportKind.privateKey));
      expect(of('-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n'), isNot(ImportKind.privateKey));
      final others = {
        'an X.509 certificate': der([0x30, 0x82, 0x01, 0x00, 0xa0, 0x03, 0x02, 0x01, 0x02, 0x02, 0x10, ...filler]),
        'an SPKI public key': der([0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, ...filler]),
        'a PKCS#1 public key': der([0x02, 0x82, 0x01, 0x01, 0x00, ...filler]),
        'a CMS message': der([0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x02, ...filler]),
      };
      others.forEach((name, bytes) => expect(importKindOf(bytes), isNot(ImportKind.privateKey), reason: name));
      // 0x30 is a "0": a file of numbers is no key.
      expect(of('0,host\n1,web1\n'), isNot(ImportKind.privateKey));
      expect(of('00000000\n'), isNot(ImportKind.privateKey));
    });
  });

  group('what only mentions a private key is not one', () {
    test('a comment naming a key\'s first line, in a config and a list', () {
      expect(of('# never paste -----BEGIN RSA PRIVATE KEY----- here\nHost web\n  HostName a.example.com\n'), ImportKind.sshConfig);
      expect(of('name,host\n# ---- BEGIN SSH2 PRIVATE KEY ----\nweb,192.0.2.1\n'), ImportKind.csv);
      expect(of('# keys: see the BEGIN PRIVATE KEY note\nHost web\n  HostName a.example.com\n'), ImportKind.sshConfig);
      expect(of('# ---- BEGIN servers ----\nHost web\n  HostName a.example.com\n# ---- END servers ----\n'), ImportKind.sshConfig);
      expect(of('Host web\n  IdentityFile ~/.ssh/PRIVATE KEY\n'), ImportKind.sshConfig);
    });

    test('the old SSH 1 file is told at its very start, and nowhere else', () {
      expect(of('name,host,note\nweb,192.0.2.1,SSH PRIVATE KEY FILE FORMAT is the old one\n'), ImportKind.csv);
      expect(of('SSH PRIVATE KEY FILE FORMAT 1.1\n'), ImportKind.privateKey);
      expect(importKindOf([...latin1.encode('SSH PRIVATE KEY FILE FORMAT 1.1\n'), 0, 0, 1, 2, 3]), ImportKind.privateKey);
      expect(importKindOf([0, 1, 2, ...latin1.encode('SSH PRIVATE KEY FILE FORMAT 1.1\n')]), ImportKind.unknown);
    });

    test('what holds nothing secret stays as it was', () {
      expect(of('-----BEGIN PUBLIC KEY-----\nMFkw\n-----END PUBLIC KEY-----\n'), isNot(ImportKind.privateKey));
      expect(of('---- BEGIN SSH2 PUBLIC KEY ----\nAAAAB3\n---- END SSH2 PUBLIC KEY ----\n'), isNot(ImportKind.privateKey));
      expect(of('-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n'), isNot(ImportKind.privateKey));
    });
  });

  group('what a person says to read all the same holds none of the key', () {
    const body = 'b3BlbnNzaC1rZXktdjEAAAAA';
    const key = '-----BEGIN OPENSSH PRIVATE KEY-----\n$body\n-----END OPENSSH PRIVATE KEY-----';
    String without(String text) => utf8.decode(importWithoutKeys(utf8.encode(text)));

    test('each line stays a line, empty where the key was', () {
      expect(without('Host web1\n$key\n  HostName 203.0.113.10\n'), 'Host web1\n\n\n\n  HostName 203.0.113.10\n');
    });

    test('every form it is told by, and more than one', () {
      for (final other in [
        '---- BEGIN SSH2 ENCRYPTED PRIVATE KEY ----\nComment: "demo"\n$body\n---- END SSH2 ENCRYPTED PRIVATE KEY ----',
        '-----BEGIN PGP PRIVATE KEY BLOCK-----\n\n$body\n-----END PGP PRIVATE KEY BLOCK-----',
        '-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\n\n$body\n-----END RSA PRIVATE KEY-----',
      ]) {
        final left = without('a\n$other\nb\n$key\nc\n');
        expect(left, isNot(contains(body)), reason: other);
        expect(left, isNot(contains('PRIVATE KEY')), reason: other);
        expect(left.split('\n').where((l) => l.isNotEmpty), ['a', 'b', 'c'], reason: other);
      }
    });

    test('in a cell of a list: the cell still closes, and what stands around it stays', () {
      final left = without('name,host,note\nweb1,203.0.113.10,"$key"\nweb2,203.0.113.11,""\n');
      expect(left, 'name,host,note\nweb1,203.0.113.10,"\n\n"\nweb2,203.0.113.11,""\n');
    });

    test('on one line, more than once', () {
      const one = '-----BEGIN RSA PRIVATE KEY-----$body-----END RSA PRIVATE KEY-----';
      expect(without('a $one b $one c\n'), 'a  b  c\n');
    });

    test('a key with no last line runs to the end: nothing after it can be told from it', () {
      expect(without('a\n-----BEGIN RSA PRIVATE KEY-----\n$body\nb\n'), 'a\n\n\n\n');
    });

    test('a comment only naming a key stays', () {
      expect(without('# -----BEGIN RSA PRIVATE KEY-----\nHost web1\n$key\n'), '# -----BEGIN RSA PRIVATE KEY-----\nHost web1\n\n\n\n');
    });

    test('whatever its line ends and its byte order mark', () {
      expect(without('\uFEFFa\r\n$key\r\nb\r\n'.replaceAll('\n$body', '\r\n$body')), 'a\n\n\n\nb\n');
    });

    test('a text made of nothing but markers takes no longer for it', () {
      const one = '-----BEGIN RSA PRIVATE KEY----------END RSA PRIVATE KEY-----';
      final text = List.filled(4 * 1024 * 1024 ~/ one.length, one).join();
      final watch = Stopwatch()..start();
      expect(without(text), isEmpty);
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });
  });

  group('a private key and more besides', () {
    ({ImportKind kind, bool moreThanKey}) look(String text) => importLookAt(utf8.encode(text));

    test('a file that is only keys is only that, however it is laid out', () {
      for (final text in [
        _opensshPrivate,
        '# my key\n$_opensshPrivate',
        '\n$_rsaPrivate\n\n',
        '$_opensshPrivate$_rsaPrivate',
        '---- BEGIN SSH2 ENCRYPTED PRIVATE KEY ----\nComment: "demo"\nP2/56wAAAAA=\n---- END SSH2 ENCRYPTED PRIVATE KEY ----\n',
        '-----BEGIN PGP PRIVATE KEY BLOCK-----\n\nlQOYBF==\n-----END PGP PRIVATE KEY BLOCK-----\n',
        '-----BEGIN RSA PRIVATE KEY-----\nno end to it\n',
        _ppk,
        'SSH PRIVATE KEY FILE FORMAT 1.1\n',
      ]) {
        final found = look(text);
        expect(found.kind, ImportKind.privateKey, reason: text);
        expect(found.moreThanKey, isFalse, reason: text);
      }
    });

    test('a key with text beside it says so, and its bytes are not kept all the same', () {
      for (final text in [
        'Host web1\n  HostName example.com\n$_opensshPrivate',
        '$_rsaPrivate\nHost web1\n  HostName example.com\n',
        'name,host,note\nweb,192.0.2.1,-----BEGIN RSA PRIVATE KEY-----\n',
      ]) {
        final found = look(text);
        expect(found.kind, ImportKind.privateKey, reason: text);
        expect(found.moreThanKey, isTrue, reason: text);
        final file = importFileOf(name: 'k', path: '/demo/k', bytes: utf8.encode(text));
        expect(file.bytes, isNull, reason: text);
        expect(file.moreThanKey, isTrue, reason: text);
        expect(importCanReadAnyway(file), isTrue, reason: text);
        expect(importCanTake(file, ImportKind.csv), isTrue, reason: text);
        // Pasted, there is no file to read again.
        final pasted = importFileOf(name: 'k', bytes: utf8.encode(text));
        expect(importCanReadAnyway(pasted), isFalse, reason: text);
        expect(importCanTake(pasted, ImportKind.csv), isFalse, reason: text);
      }
      // What is only a key, nothing else may read.
      final only = importFileOf(name: 'k', path: '/demo/k', bytes: utf8.encode(_opensshPrivate));
      expect(importCanReadAnyway(only), isFalse);
      expect(importCanTake(only, ImportKind.csv), isFalse);
    });
  });

  group('a share link under a comment', () {
    const link = 'zestssh://add-host?host=web1.example.com&port=22';

    test('is one, and only its line goes on', () {
      for (final text in ['# from the wiki\n$link\n', '$link\n# from the wiki\n', '\r\n$link\r\n', link]) {
        expect(of(text), ImportKind.shareLink, reason: text);
        expect(importShareLinkOf(utf8.encode(text)), link, reason: text);
      }
    });

    test('two lines of anything else are not', () {
      expect(of('$link\nmore\n'), isNot(ImportKind.shareLink));
      expect(importShareLinkOf(utf8.encode('$link\nmore\n')), isNull);
    });
  });

  group('a backup is told by its version as well', () {
    test('a text or CSV file that starts with those letters is not a backup', () {
      expect(of('ZEST,host\nweb,web1.example.com\n'), isNot(ImportKind.zestBackup));
      expect(of('Name,Host\nweb,web1.example.com\n'.replaceFirst('Name', 'ZESTY')), isNot(ImportKind.zestBackup));
      expect(of('ZESTY notes\n'), ImportKind.unknown);
      expect(of('ZEST host,name\nweb1,Web\n'), isNot(ImportKind.zestBackup));
      expect(of('ZEST\twhat,host\nx,web1.example.com\n'), isNot(ImportKind.zestBackup), reason: 'a tab is text');
      expect(of('ZEST\nnotes\n'), isNot(ImportKind.zestBackup));
      for (final b in ['ZEST,', 'ZEST ', 'ZEST\t', 'ZEST\n', 'ZEST\r', 'ZESTY']) {
        expect(BackupService.isBackupFile(utf8.encode(b)), isFalse, reason: b);
      }
      expect(BackupService.isBackupFile([...utf8.encode('ZEST'), 0, 1, 2]), isFalse, reason: 'no version 0');
    });

    test('each version there has been, and those to come, is', () {
      for (final version in [1, 2, 3, 4, 8]) {
        expect(BackupService.isBackupFile([...utf8.encode('ZEST'), version, 1, 2]), isTrue, reason: '$version');
        expect(importKindOf([...utf8.encode('ZEST'), version, 1, 2]), ImportKind.zestBackup, reason: '$version');
      }
    });
  });

  group('a private key is read for a yes or no, and no further', () {
    test('its bytes are not kept', () {
      final file = importFileOf(name: 'id_ed25519', path: '/home/demo/.ssh/id_ed25519', bytes: utf8.encode(_opensshPrivate));
      expect(file.kind, ImportKind.privateKey);
      expect(file.bytes, isNull);
      expect(file.picked, isNull);
      expect(importCanTake(file, ImportKind.privateKey), isTrue);
    });

    test('pasted, it has no file to go on with', () {
      final file = importFileOf(name: 'Pasted', bytes: utf8.encode(_opensshPrivate));
      expect(importCanTake(file, ImportKind.privateKey), isFalse);
    });

    test('anything else keeps what was read, for its import', () {
      final file = importFileOf(name: 'hosts.csv', bytes: utf8.encode(_csv));
      expect(file.bytes, isNotNull);
      expect(file.picked!.name, 'hosts.csv');
      expect(importCanTake(file, ImportKind.csv), isTrue);
    });
  });

  group('PuTTY\'s .reg file', () {
    test('its sessions: names unescaped, ports in hexadecimal, a user in the host, others left out', () {
      final read = readHostFile(_puttyReg);
      expect(read.problem, isNull);
      expect([for (final r in read.rows) r.name], ['web 1', 'switch']);
      final web = read.rows.first;
      expect((web.host, web.port, web.user, web.protocol), ('web1.example.com', 2222, 'deploy', 'ssh'));
      final sw = read.rows.last;
      expect((sw.host, sw.port, sw.user, sw.protocol), ('192.0.2.1', 23, 'admin', 'telnet'));
    });

    test('in UTF-16, as regedit writes it', () {
      final read = readHostFile(decodeCsvBytes(_utf16(_puttyReg)));
      expect(read.rows, hasLength(2));
    });

    test('a .reg of something else, or with no session, has no hosts', () {
      expect(readPuttyRegHosts('Windows Registry Editor Version 5.00\n\n[HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\SshHostKeys]\n"a"="b"\n').problem,
          CsvFileProblem.empty);
      expect(hostFileKindOf('Windows Registry Editor Version 5.00\n\n[HKEY_CURRENT_USER\\Software\\Other]\n'), HostFileKind.csv);
    });
  });

  group('the host file kinds are told as they were', () {
    test('each is its own', () {
      expect(hostFileKindOf(_mobaXterm), HostFileKind.mobaxterm);
      expect(hostFileKindOf(_secureCrtXml), HostFileKind.securecrt);
      expect(hostFileKindOf(_secureCrtIni), HostFileKind.securecrt);
      expect(hostFileKindOf(_puttyReg), HostFileKind.putty);
      expect(hostFileKindOf(_csv), HostFileKind.csv);
    });

    test('and the kinds say which import reads them', () {
      expect(ImportKind.mobaxterm.hostFile, HostFileKind.mobaxterm);
      expect(ImportKind.secureCrt.hostFile, HostFileKind.securecrt);
      expect(ImportKind.puttyReg.hostFile, HostFileKind.putty);
      expect(ImportKind.csv.hostFile, HostFileKind.csv);
      expect(ImportKind.zestBackup.hostFile, isNull);
      expect(ImportKind.privateKey.isHostFile, isFalse);
    });
  });
}
