import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/sftp_service.dart';

/// What the file editor asks of a host's shell about a file (3.4): its
/// owner and mode, whether the login account may write it, whether sudo is
/// there; and how Save as root runs sudo and reads its answer.
void main() {
  group('the access script', () {
    test('reads its three lines', () {
      final a = SftpService.readAccess('root:root 644\nr\nsudo\n')!;
      expect(a.owner, 'root:root');
      expect(a.mode, '644');
      expect(a.writable, isFalse);
      expect(a.sudo, isTrue);
      final b = SftpService.readAccess('deploy:deploy 600\nw\nnosudo')!;
      expect((b.owner, b.mode, b.writable, b.sudo), ('deploy:deploy', '600', true, false));
    });

    test('a stat it could not run leaves owner and mode unknown, the rest read', () {
      final a = SftpService.readAccess('?\nr\nsudo')!;
      expect(a.owner, isNull);
      expect(a.mode, isNull);
      expect(a.writable, isFalse);
    });

    test('anything else is not taken for an answer', () {
      expect(SftpService.readAccess(''), isNull);
      expect(SftpService.readAccess('Permission denied'), isNull);
      expect(SftpService.readAccess('root:root 644\nmaybe\nsudo'), isNull);
    });

    test('runs under sh with the path as its argument, never in its text', () {
      expect(SftpService.accessScript, contains(r'p="$1"'));
      expect(SftpService.accessScript, isNot(contains("'")), reason: 'it stands in single quotes');
    });
  });

  group('Save as root', () {
    test('sudo asks for the password every time, reads it from its input, prints no prompt, and copies with cp', () {
      final cmd = SftpService.sudoCopyCommand('/tmp/.zestssh-edit-ab12', "/etc/nginx/it's.conf");
      expect(cmd, startsWith("env LC_ALL=C sudo -k -S -p '' -- cp -- "));
      expect(cmd, contains('/tmp/.zestssh-edit-ab12'));
      expect(cmd, isNot(contains("/etc/nginx/it's.conf ")), reason: 'the path is quoted');
    });

    test('what sudo says is read: a wrong password, an account that may not, else what it said', () {
      expect(SftpService.sudoRefusal('Sorry, try again.\nsudo: 1 incorrect password attempt\n'), isA<SudoPasswordException>());
      expect(SftpService.sudoRefusal('sudo: no password was provided'), isA<SudoPasswordException>());
      expect(SftpService.sudoRefusal('deploy is not in the sudoers file.  This incident will be reported.'),
          isA<SudoNotAllowedException>());
      expect(SftpService.sudoRefusal('Sorry, user deploy is not allowed to execute /usr/bin/cp as root on web-01.'),
          isA<SudoNotAllowedException>());
      final other = SftpService.sudoRefusal('cp: cannot create regular file: Read-only file system');
      expect(other, isA<SudoFailedException>());
      expect((other as SudoFailedException).said, contains('Read-only file system'));
    });

    test('its failures name their types', () {
      expect(const SudoPasswordException().typeName, 'SudoPasswordException');
      expect(const SudoNotAllowedException('x').typeName, 'SudoNotAllowedException');
      expect(const SudoFailedException('x').typeName, 'SudoFailedException');
    });
  });
}
