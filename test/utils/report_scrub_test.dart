import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/utils/redactor.dart';
import 'package:zestssh/utils/report_scrub.dart';

/// What an error report may hold once it is copied: no secret, and nothing
/// that says which hosts, people or folders someone has. Every name and
/// address here is made up.
void main() {
  final bs = String.fromCharCode(92);
  String win(String path) => path.replaceAll('/', bs);

  setUp(() {
    Redactor.instance
      ..clearNames()
      ..salt = 'a test'
      ..level = RedactLevel.layout
      ..enabled = false;
    ReportScrub.clearFolders();
  });

  tearDown(() {
    Redactor.instance.clearNames();
    ReportScrub.clearFolders();
  });

  String scrub(String text) => ReportScrub.scrub(text);

  group('What is no secret and names nobody stays as it is', () {
    test('plain words, numbers, times and versions', () {
      for (final text in [
        '',
        'The database could not be opened.',
        'SocketException: Connection refused (OS Error: Connection refused, errno = 111)',
        'HTTP 403 recent-sign-in-required',
        'ZestSSH 3.0.0 (build 256)',
        'windows "Windows 11 Pro" 10.0 (Build 26200)',
        '2026-10-02 14:03:22 UTC',
        '[14:03:21.120] WARNING: Orchards: sync did not finish',
        'Bad state: No element',
        'RangeError (index): Invalid value: Not in inclusive range 0..3: 7',
        'step 3 of 12, 45% done, 1.5 MB/s',
        'the token expired and the password was wrong',
        'TLS/SSL and/or 10/12',
      ]) {
        expect(scrub(text), text, reason: text);
      }
    });

    test('the lines of a stack, with the app\'s own files', () {
      const stack = '#0      OrchardService.refresh (package:zestssh/features/orchards/orchard_service.dart:412:7)\n'
          '#1      _rootRunUnary (dart:async/zone.dart:1538:47)\n'
          '#2      AppDatabase.open (package:zestssh/database/database.g.dart:20311:5)\n'
          '#3      main.<anonymous closure> (package:drift/src/runtime/api/connection.dart:88:12)';
      expect(scrub(stack), stack);
      expect(scrub('in database.g.dart and app_localizations_en.dart'),
          'in database.g.dart and app_localizations_en.dart');
    });

    test('an id of the app\'s own making', () {
      const id = 'Orchard: 0b0e7d1c-3f5a-4a44-9b1d-2f6c8e4a7d10';
      expect(scrub(id), id);
    });
  });

  group('Secrets', () {
    test('a private key, whole or cut short, and a PuTTY one', () {
      const key = '-----BEGIN OPENSSH PRIVATE KEY-----\n'
          'b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW\n'
          'QyNTUxOQAAACD0000000000000000000000000000000000000000000\n'
          '-----END OPENSSH PRIVATE KEY-----';
      expect(scrub('before\n$key\nafter'), 'before\n[private key removed]\nafter');
      expect(scrub('-----BEGIN RSA PRIVATE KEY-----\nMIIEow'), '[private key removed]');
      expect(scrub('-----BEGIN PRIVATE KEY-----\nMIIEvQ\n-----END PRIVATE KEY----- x'), '[private key removed] x');
      const putty = 'PuTTY-User-Key-File-3: ssh-ed25519\nEncryption: none\nComment: demo\n'
          'Public-Lines: 2\nAAAAC3Nz\nPrivate-Lines: 1\nAAAAIH\nPrivate-MAC: 00ff';
      expect(scrub('$putty\nafter'), '[private key removed]\nafter');
    });

    test('a public key with its comment, and fingerprints', () {
      expect(scrub('key ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDemoDemoDemoDemoDemoDemoDemoDemoDemoDemo demo@web-01 end'),
          'key [public key removed] end');
      expect(scrub('ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTY='), '[public key removed]');
      expect(scrub('ssh-rsa-cert-v01@openssh.com AAAAHHNzaC1yc2EtY2VydA== id'), '[public key removed]');
      expect(scrub('SHA256:nThbg6kXUpJWGl7E1IGOCspRomTxdCARLviKw6E5SY8 seen'), 'SHA256:[removed] seen');
      expect(scrub('MD5 16:27:ac:a5:76:28:2d:36:63:1b:56:4d:eb:df:a6:48.'), 'MD5 [fingerprint removed].');
      // A clock time is no fingerprint. Nor is the address of a network
      // card, which is masked as the address it is.
      final card = scrub('at 12:30:45 on 00:1b:44:11:3a:b7');
      expect(card, startsWith('at 12:30:45 on '));
      expect(card, isNot(contains('fingerprint')));
      expect(card, isNot(contains('00:1b:44')));
    });

    test('what a field calls a password, a passphrase, a secret, a token or a key', () {
      expect(scrub('password=hunter2'), 'password=[removed]');
      expect(scrub('Password: hunter2, next'), 'Password: [removed], next');
      expect(scrub('passphrase : "two words"'), 'passphrase : [removed]');
      expect(scrub("pwd='x y' z"), 'pwd=[removed] z');
      expect(scrub('{"db_password":"s3cret","user":"demo"}'), '{"db_password":[removed],"user":"demo"}');
      expect(scrub('access_token=abc123&refresh-token=def456&page=2'),
          'access_token=[removed]&refresh-token=[removed]&page=2');
      expect(scrub('client_secret: abc; api_key = k1; apikey=k2; otp: 123456; PRIVATE_KEY=zz'),
          'client_secret: [removed]; api_key = [removed]; apikey=[removed]; otp: [removed]; PRIVATE_KEY=[removed]');
      // A word that only begins like one is no field.
      expect(scrub('passwordless: true, tokens: 3'), 'passwordless: true, tokens: 3');
    });

    test('headers that carry who is signed in, and what follows Bearer or Basic', () {
      expect(scrub('Authorization: Bearer abc.def-ghi\nAccept: */*'), 'Authorization: [removed]\nAccept: */*');
      expect(scrub('cookie: sid=1; theme=dark'), 'cookie: [removed]');
      expect(scrub('sent Bearer abcdefgh12345678 to it'), 'sent Bearer [removed] to it');
      expect(scrub('Basic ZGVtbzpodW50ZXIy'), 'Basic [removed]');
      expect(scrub('a Basic plan, a Bearer of news'), 'a Basic plan, a Bearer of news');
    });

    test('what looks like a token or like data', () {
      expect(scrub('jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJkZW1vIn0.c2lnbmF0dXJlMTIzNDU2 end'), 'jwt [token removed] end');
      expect(scrub('hash 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08'), 'hash [data removed]');
      expect(scrub('blob QWxhZGRpbjpvcGVuIHNlc2FtZSBhbmQgbW9yZSBkYXRhIDEyMzQ1Njc4OTA= end'), 'blob [data removed] end');
      // Long, and no data: a name in code, a sentence without blanks in it.
      for (final text in [
        'a_very_long_test_name_that_goes_on_and_on_and_on_and_on',
        'OrchardSyncCoordinatorNotifierProviderElementImplementation',
        'thirty-nine-characters-and-a-few-more-of-them-here',
      ]) {
        expect(scrub(text), text, reason: text);
      }
    });
  });

  group('Web addresses', () {
    test('one of ZestSSH\'s own keeps its path and loses its query', () {
      expect(scrub('GET https://api.zestssh.com/v1/orchards/0b0e7d1c/record?after=12&sig=abc failed'),
          'GET https://api.zestssh.com/v1/orchards/0b0e7d1c/record?[removed] failed');
      expect(scrub('see https://zestssh.com/app/latest.json'), 'see https://zestssh.com/app/latest.json');
      // A host that only ends like it is not it.
      expect(scrub('https://notzestssh.com/x'), isNot(contains('notzestssh')));
    });

    test('one of a service everybody uses keeps its host only', () {
      expect(scrub('https://www.googleapis.com/drive/v3/files/1AbCdEf?alt=media'),
          'https://www.googleapis.com/[removed]');
      expect(scrub('https://api.dropboxapi.com'), 'https://api.dropboxapi.com');
    });

    test('any other is masked whole, with who signs in there', () {
      final out = scrub('PUT https://demo:hunter2@dav.northwind.example:8443/remote.php/files/demo/zestssh.zest?x=1 401');
      expect(out, startsWith('PUT https://host-'));
      expect(out, endsWith('.example.invalid:8443/[removed] 401'));
      for (final leak in ['demo', 'hunter2', 'northwind', 'remote.php', 'zestssh.zest']) {
        expect(out, isNot(contains(leak)), reason: leak);
      }
      expect(scrub('sftp://10.50.0.11:22'), startsWith('sftp://192.0.2.'));
      expect(scrub('sftp://10.50.0.11:22'), endsWith(':22'));
      expect(scrub('http://[fe80::1]:8080/a'), startsWith('http://[2001:db8::'));
    });

    test('a file by its address is looked at as a path', () {
      expect(scrub('at file:///C:/Users/demo/app/lib/main.dart:10:5'), 'at C:/Users/<user>/<name>/lib/main.dart:10:5');
      expect(scrub('file:///home/demo/notes/list.txt'), '/home/<user>/<name>/<file>.txt');
    });
  });

  group('Folders and files', () {
    test('a folder the app was told about is called by what it is', () {
      ReportScrub.registerFolder(win('C:/Users/demo/AppData/Roaming/ZestSSH/'), '<app data>');
      ReportScrub.registerFolder(win('C:/Users/demo/Documents'), '<documents>');
      ReportScrub.registerFolder(win('C:/Users/demo'), '<home>');
      expect(scrub('opening ${win('C:/Users/demo/AppData/Roaming/ZestSSH/zestssh.db')} failed'),
          'opening <app data>${bs}zestssh.db failed');
      // Written the other way round, and in other letters, it is the same folder.
      expect(scrub('c:/users/DEMO/documents/Northwind/keys/prod.pem'), '<documents>/<name>/<name>/<file>.pem');
      expect(scrub(win('C:/Users/demo/Pictures/shot.png')), '<home>$bs<name>$bs<file>.png');
      // A drive or a root is never taken for one: everything is under it.
      ReportScrub.registerFolder('C:$bs', '<home>');
      ReportScrub.registerFolder('/', '<home>');
      expect(scrub(win('C:/Windows/System32/drivers')), win('C:/Windows/System32/<name>'));
    });

    test('an account\'s own folder says nothing of whose it is', () {
      expect(scrub(win('C:/Users/Demo Person/AppData/Local/Temp/x.log')),
          win('C:/Users/<user>/AppData/Local/Temp/<file>.log'));
      expect(scrub('/home/demo/.ssh/id_ed25519'), '/home/<user>/.ssh/id_ed25519');
      expect(scrub('/Users/demo/Library/Application Support/com.affluentlabs.zestssh/zestssh.db'),
          '/Users/<user>/Library/Application Support/com.affluentlabs.zestssh/zestssh.db');
      expect(scrub('the app com.affluentlabs.zestssh was stopped'), 'the app com.affluentlabs.zestssh was stopped');
      expect(scrub('/mnt/c/Users/demo/x'), '/mnt/<name>/Users/<user>/<name>');
    });

    test('of the rest only the names every computer has stay', () {
      expect(scrub('No such file: /srv/northwind/releases/2026-10/app.tar'),
          'No such file: /srv/<name>/<name>/<name>/<file>.tar');
      expect(scrub('/etc/ssh/sshd_config'), '/etc/<name>/<name>');
      expect(scrub('~/work/client-a/notes'), '~/<name>/<name>/<name>');
      expect(scrub('/var/log/'), '/var/<name>/');
      expect(scrub(win('D:/Backups/Northwind Ops/2026/team.json')), win('D:/Backups/<name>/<name>/<file>.json'));
      expect(scrub('"${win('C:/Program Files/ZestSSH/zestssh.exe')}" admin plan'),
          '"${win('C:/Program Files/ZestSSH/zestssh.exe')}" admin plan');
      // What comes after a path on the same line is not part of it.
      expect(scrub('Cannot open ${win('C:/Temp/a b.txt')}: Access is denied'),
          'Cannot open ${win('C:/Temp/<file>.txt')}: Access is denied');
      expect(scrub("path = '/data/user/0/com.affluentlabs.zestssh/files/keys/web.pem' (OS Error)"),
          "path = '/data/user/0/com.affluentlabs.zestssh/files/<name>/<file>.pem' (OS Error)");
    });

    test('a share on another computer does not say which', () {
      expect(scrub('$bs${bs}nas-01${bs}backups${bs}zest${bs}a.zip'), '$bs$bs<server>${bs}backups$bs<name>$bs<file>.zip');
    });

    test('a file named by itself keeps what it is, not what it is called', () {
      expect(scrub('could not read northwind-team.json'), 'could not read <file>.json');
      expect(scrub('saved as web-1.northwind.example.zest'), 'saved as <file>.zest');
      expect(scrub('zestssh.db is locked; known_hosts and latest.json are fine'),
          'zestssh.db is locked; known_hosts and latest.json are fine');
      // A word with a full stop after it is no file.
      expect(scrub('It failed. Try again.'), 'It failed. Try again.');
      expect(scrub('version 3.0.0, build 256.'), 'version 3.0.0, build 256.');
    });
  });

  group('Names and addresses', () {
    test('who signs in where, addresses and names with dots', () {
      final out = scrub('demo@web-01.northwind.example refused; 10.50.0.11:22 timed out; fe80::1ff:fe23:4567:890a too');
      for (final leak in ['demo@', 'web-01', 'northwind', '10.50.0.11', 'fe80::1ff']) {
        expect(out, isNot(contains(leak)), reason: leak);
      }
      expect(out, contains('.example.invalid refused'));
      expect(out, contains(':22 timed out'));
    });

    test('every name the app knows something by, in any sentence, recording or not', () {
      Redactor.instance
        ..registerNames(['web-01', 'Production', 'Northwind Ops'])
        ..registerAddresses(['bastion', 'db.internal']);
      expect(Redactor.instance.enabled, isFalse);
      final out = scrub('Connecting to web-01 through bastion failed; Production of Northwind Ops is closed; db.internal too');
      for (final leak in ['web-01', 'bastion', 'Production', 'Northwind', 'db.internal']) {
        expect(out, isNot(contains(leak)), reason: leak);
      }
      expect(out, startsWith('Connecting to '));
      expect(out, contains(' failed; '));
    });

    test('scrubbing what was scrubbed changes nothing more', () {
      Redactor.instance.registerNames(['web-01']);
      ReportScrub.registerFolder('/home/demo/.local/share/zestssh', '<app data>');
      const text = 'web-01: demo@10.50.0.11 password=x https://dav.northwind.example/a?b=c '
          '/home/demo/.local/share/zestssh/zestssh.db /srv/app/run.log token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJkZW1vIn0.c2lnbmF0dXJl';
      final once = scrub(text);
      expect(scrub(once), once);
      expect(once, contains('<app data>/zestssh.db'));
    });

    test('text that holds the marks this uses for itself comes out without them', () {
      final odd = 'a${String.fromCharCode(0xe000)}0${String.fromCharCode(0xe001)}b /srv/x';
      expect(scrub(odd), 'a0b /srv/<name>');
    });
  });

  group('What a security review found let through', () {
    test('a domain with a single dot, and one inside a team', () {
      expect(scrub('Connecting to acme-billing.com failed'), 'Connecting to <domain> failed');
      // (One with more dots was masked as an address already.)
      expect(scrub('db.corp.lan:5432 refused'), isNot(contains('corp')));
      // Ours, everybody's, versions, code and files stay.
      for (final text in ['zestssh.com is fine', 'github.com is fine', 'version 3.4.0', 'SftpService.open failed', 'zone.dart']) {
        expect(scrub(text), text, reason: text);
      }
    });

    test('a username the app signs in with, by itself or quoted, and a host it keeps', () {
      ReportScrub.registerUsernames(['deploybot', 'root', 'ab']);
      ReportScrub.registerHosts(['prod-db-7', 'Billing Edge']);
      expect(scrub('Authenticating as deploybot'), 'Authenticating as <user>');
      expect(scrub("user 'deploybot' refused"), "user '<user>' refused");
      expect(scrub('Disconnected from prod-db-7'), 'Disconnected from <host>');
      expect(scrub('trigger "Billing Edge" ran'), 'trigger "<host>" ran');
      // An account every server has, and a short one, names nobody.
      expect(scrub('permission denied for root, ab'), 'permission denied for root, ab');
      // A word that only holds one is no name.
      expect(scrub('deploybots and prod-db-77'), 'deploybots and prod-db-77');
    });

    test('a secret after a blank, not only after = or :', () {
      expect(scrub('password hunter2 rejected'), 'password [removed] rejected');
      expect(scrub('db_password s3cret'), 'db_password [removed]');
      expect(scrub('access token abc123 used'), 'access token [removed] used');
      expect(scrub('Password authentication failed for this user'), 'Password authentication failed for this user');
    });

    test('tokens known by how they begin', () {
      for (final token in [
        'xoxb-123456789012-abcdefghijkl',
        'sk_live_51HdemoDemoDemo0000',
        'rk_live_51HdemoDemoDemo0000',
        'pk_live_51HdemoDemoDemo0000',
        'sk_test_51HdemoDemoDemo0000',
        'ghp_DemoDemoDemoDemoDemoDemo0000',
        'gho_DemoDemoDemoDemoDemoDemo0000',
        'github_pat_11ADEMO0000_demoDemo',
        'AKIAIOSFODNN7EXAMPLE',
      ]) {
        expect(scrub('key $token end'), 'key [token removed] end', reason: token);
      }
      expect(scrub('Authorization was Bearer abc.def'), 'Authorization was Bearer [removed]');
      expect(scrub('jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJkZW1vIn0.c2lnbmF0dXJl'), 'jwt [token removed]');
    });

    test('a hex key of 32 characters and a mixed one of 24', () {
      expect(scrub('key 0123456789abcdef0123456789abcdef end'), 'key [data removed] end');
      expect(scrub('id Ab3dE6gH9jK2mN5pQ8rS1tV4 end'), 'id [data removed] end');
    });

    test('a PEM block of any kind', () {
      expect(scrub('-----BEGIN CERTIFICATE-----\nMIIBszCCAVmgAwIBAgIU\n-----END CERTIFICATE----- ok'), '[PEM block removed] ok');
    });

    test('a one-time code after the word for it', () {
      expect(scrub('totp 123456 rejected'), 'totp [removed] rejected');
      expect(scrub('otp 123456 rejected'), 'otp [code removed] rejected');
      expect(scrub('2FA code is 654321'), '2FA code is [code removed]');
      expect(scrub('code: 12345678'), 'code: [code removed]');
      expect(scrub('exit code 1, HTTP code 403'), 'exit code 1, HTTP code 403');
    });

    test('files named by themselves', () {
      expect(scrub('report-acme-q3.xlsx and deploy-acme-prod.sh'), '<file>.xlsx and <file>.sh');
    });
  });

  group('What the first checks of this missed (3.0, its mutation check)', () {
    test('a run of data with slashes in it, and a path that only looks long', () {
      // Data may hold slashes (base64 does); with many digits it is data.
      expect(scrub('blob ab12/Cd34/Ef56/Gh78/Ij90/Kl12/Mn34/Op56/Qr78 end'), 'blob [data removed] end');
      // A path with a digit or two in it is a path, written without blanks.
      expect(scrub('in Assets/Images/Icons/AppIcon2/Toolbar/Search'), 'in Assets/Images/Icons/AppIcon2/Toolbar/Search');
      // Digits and small letters only, a name in a build: no data.
      expect(scrub('build_2026_10_02_release_candidate_number_7'), 'build_2026_10_02_release_candidate_number_7');
    });

    test('a port or brackets around an address do not make it another host, and ours keeps its path', () {
      for (final url in ['https://dav.northwind.example:8443/x', 'http://[fe80::1]:8080/a', 'sftp://10.50.0.11:22']) {
        final once = scrub(url);
        expect(scrub(once), once, reason: url);
      }
      expect(scrub('https://api.zestssh.com:443/v1/status'), 'https://api.zestssh.com:443/v1/status');
    });

    test('a query or a part after the host alone is said to be taken out', () {
      expect(scrub('https://accounts.google.com?continue=x'), 'https://accounts.google.com/[removed]');
      expect(scrub('https://github.com#readme'), 'https://github.com/[removed]');
      expect(scrub('https://accounts.google.com'), 'https://accounts.google.com');
    });

    test('a folder is called only by a token, the longest first, and the last word on it stands', () {
      // A word that is no token would stand where the folder's name was.
      ReportScrub.registerFolder('/srv/northwind', 'northwind');
      expect(scrub('/srv/northwind/a'), '/srv/<name>/<name>');
      // Told the wider folder first, the narrower one still wins inside it.
      ReportScrub.registerFolder('/home/demo', '<home>');
      ReportScrub.registerFolder('/home/demo/.local/share/zestssh', '<app data>');
      expect(scrub('/home/demo/.local/share/zestssh/zestssh.db'), '<app data>/zestssh.db');
      // Told again, by another word, the last stands.
      ReportScrub.registerFolder('/home/demo/docs', '<documents>');
      ReportScrub.registerFolder('/home/demo/docs', '<downloads>');
      expect(scrub('/home/demo/docs/a'), '<downloads>/<name>');
    });

    test('an ending nobody knows is part of a name, and a step up a folder stays', () {
      expect(scrub('/var/www/shop.northwind'), '/var/<name>/<name>');
      expect(scrub('/opt/app/../logs/run.log'), '/opt/<name>/../logs/<file>.log');
    });

    test('a path ends where a file or a folder every computer has does, and the words after it stay', () {
      final bs = String.fromCharCode(92);
      String win(String path) => path.replaceAll('/', bs);
      expect(scrub('Cannot read ${win('C:/Temp/x.log')} because it is locked'),
          'Cannot read ${win('C:/Temp/<file>.log')} because it is locked');
      expect(scrub('at ${win('C:/src/app/lib/main.dart')} line 5'), 'at ${win('C:/<name>/<name>/lib/main.dart')} line 5');
      expect(scrub('in ${win('C:/Users/demo/Documents')} now'), 'in ${win('C:/Users/<user>/Documents')} now');
      // Past the first blank as well.
      expect(scrub('see ${win('C:/Temp/old notes.txt')} for it'), 'see ${win('C:/Temp/<file>.txt')} for it');
    });

    test('an address right after a path is taken out once, and nothing set aside is left in the text', () {
      final out = scrub('/srv/https://dav.northwind.example/a');
      expect(out, startsWith('/srv/https://host-'));
      expect(out, endsWith('.example.invalid/[removed]'));
      expect(out.contains(String.fromCharCode(0xe000)) || out.contains(String.fromCharCode(0xe001)), isFalse);
    });
  });
}
