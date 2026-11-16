import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/password_managers/password_manager_import.dart';
import 'package:zestssh/features/password_managers/password_manager_ref.dart';
import 'package:zestssh/features/password_managers/password_managers.dart';

/// Adding keys and hosts from a password manager (3.0): a key per
/// item holding only its reference; a host for an item whose address is an
/// SSH one; a web address, or anything that does not read as a host, makes
/// no host.
void main() {
  test('SSH addresses read as hosts; web addresses and names do not', () {
    expect(sshTargetOf('ssh://deploy@web1.example.com:2222'), (host: 'web1.example.com', port: 2222, user: 'deploy'));
    expect(sshTargetOf('ssh://web1.example.com'), (host: 'web1.example.com', port: 22, user: null));
    expect(sshTargetOf('ssh://gw/'), (host: 'gw', port: 22, user: null));
    expect(sshTargetOf('root@10.0.0.5'), (host: '10.0.0.5', port: 22, user: 'root'));
    expect(sshTargetOf('db.internal:2200'), (host: 'db.internal', port: 2200, user: null));
    expect(sshTargetOf('ssh://admin@[2001:db8::1]:22'), (host: '2001:db8::1', port: 22, user: 'admin'));
    for (final bad in [
      null,
      '',
      'https://github.com/login',
      'http://10.0.0.5',
      'ftp://files.example.com',
      'My server',
      'bank',
      'ssh://-oProxyCommand=evil',
      'ssh://-evil.example.com',
      'deploy@-evil.example.com:22',
      'ssh://host:99999',
      'ssh://host/path',
      'ssh://us er@host',
      'ssh://host?x=1',
      'a b.example.com',
    ]) {
      expect(sshTargetOf(bad), isNull, reason: '$bad');
    }
  });

  test('a key per item, keeping only its reference; a host where the address is an SSH one', () async {
    final keys = <(String, String, String)>[];
    final hosts = <(String, String, int, String)>[];
    final items = [
      PasswordManagerItem(
          title: 'web1', username: 'deploy', url: 'ssh://web1.example.com:2222', ref: PasswordRef.onePassword('op://Eng/web1/password')!),
      PasswordManagerItem(title: 'GitHub', username: 'me', url: 'https://github.com', ref: PasswordRef.onePassword('op://Eng/GitHub/password')!),
      PasswordManagerItem(title: 'db', url: 'root@db.internal', ref: PasswordRef.bitwarden('5f2c0e3a-1b2c-4d3e-8f9a-0b1c2d3e4f5a')!),
      PasswordManagerItem(title: ' ', ref: PasswordRef.keePassXc('Servers/nameless')!),
    ];
    var n = 0;
    final done = await addFromPasswordManager(items,
        createKey: ({required label, required username, required passwordRef}) async {
          keys.add((label, username, passwordRef));
          return 'k${n++}';
        },
        createHost: ({required label, required host, required port, required keyId}) async {
          hosts.add((label, host, port, keyId));
          return 'h';
        },
        fallbackUser: 'me-here');
    expect((done.keys, done.hosts), (4, 2));
    expect([for (final k in keys) (k.$1, k.$2, PasswordRef.decode(k.$3)?.target)], [
      ('web1', 'deploy', 'op://Eng/web1/password'),
      ('GitHub', 'me', 'op://Eng/GitHub/password'),
      ('db', 'root', '5f2c0e3a-1b2c-4d3e-8f9a-0b1c2d3e4f5a'),
      ('Servers/nameless', 'me-here', 'Servers/nameless'),
    ]);
    expect(hosts, [('web1', 'web1.example.com', 2222, 'k0'), ('db', 'db.internal', 22, 'k2')]);
  });
}
