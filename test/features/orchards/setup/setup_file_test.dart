import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/setup/setup_file.dart';

// The setup file by itself (3.0): what it may hold, every way a
// file can be wrong (each said with its place) and how it is written.

/// A file from [body], the fields after the marker.
String _file(Map<String, Object?> body) => jsonEncode({kSetupFileMarker: 1, ...body});

SetupFile _read(Map<String, Object?> body) {
  final read = readSetupFile(_file(body));
  expect(read.problems.map((p) => '$p').toList(), isEmpty);
  return read.file!;
}

/// What is wrong with a file of [body], as text, in the order found.
List<String> _wrong(Map<String, Object?> body) {
  final read = readSetupFile(_file(body));
  expect(read.file, isNull, reason: 'a file with something wrong with it is not read');
  return [for (final p in read.problems) '$p'];
}

final _bs = String.fromCharCode(92);

void main() {
  group('what makes a setup file', () {
    test('text that is not JSON says where it stops being JSON', () {
      final read = readSetupFile('{\n  "zestssh_setup": 1,\n  "crates": [}\n');
      expect(read.ok, isFalse);
      expect(read.file, isNull);
      final p = read.problems.single;
      expect(p.fault, SetupFileFault.notJson);
      expect(p.path, '');
      expect(p.line, 3);
      expect(p.column, 14);
    });

    test('nothing at all is not JSON', () {
      expect(readSetupFile('').problems.single.fault, SetupFileFault.notJson);
    });

    test('JSON that is not a setup file says so, and nothing more', () {
      for (final text in [
        '[]',
        '"zestssh_setup"',
        '{}',
        '{"crates": []}',
        '{"zestssh_setup": "1"}',
        '{"zestssh_setup": 1.5}',
        '{"zestssh_setup": 0}',
        '{"zestssh_setup": -1}',
        '{"zestssh_setup": true, "nonsense": 1}',
      ]) {
        final read = readSetupFile(text);
        expect(read.ok, isFalse, reason: text);
        expect(read.problems.map((p) => '$p'), ['notSetupFile'], reason: text);
      }
    });

    test('a file written for a newer version is not read as this one', () {
      final read = readSetupFile('{"zestssh_setup": 4, "crates": 7}');
      expect(read.problems.map((p) => '$p'), ['newerVersion zestssh_setup 4']);
      expect(kSetupFileVersion, 3);
    });

    test('a file of the first version and one of the second, which names limits, are both read', () {
      for (final version in [1, 2]) {
        final read = readSetupFile('{"zestssh_setup": $version, "members": [{"email": "ada@northwind.example", '
            '"limits": {"Production": "connect"}}]}');
        expect(read.problems, isEmpty, reason: '$version');
        expect(read.file!.members!.single.limits, {'Production': levelSwitches(CrateLevel.connect)});
      }
    });

    test('the smallest file is one that says nothing', () {
      final file = readSetupFile('{"zestssh_setup": 1}').file!;
      expect(file.orchard, isNull);
      expect(file.rules, isNull);
      expect(file.records, isNull);
      expect(file.crates, isNull);
      expect(file.roles, isNull);
      expect(file.members, isNull);
      expect(writeSetupFile(file), '{\n  "zestssh_setup": 1\n}\n');
    });

    test('a file past the longest one is not even decoded', () {
      final text = '{"zestssh_setup": 1, "orchard": "${'a' * kSetupFileMaxChars}"}';
      expect(readSetupFile(text).problems.map((p) => '$p'), ['tooBig max $kSetupFileMaxChars']);
      // One at the limit is read (and is wrong for another reason).
      final atLimit = '{"zestssh_setup": 1, "orchard": "${'a' * (kSetupFileMaxChars - 35)}"}';
      expect(atLimit.length, kSetupFileMaxChars);
      expect(readSetupFile(atLimit).problems.map((p) => '$p'), ['tooLong orchard max 50']);
    });
  });

  group('a whole file', () {
    final whole = {
      'orchard': ' Northwind Ops ',
      'rules': {
        'require_2fa': true,
        'email_domains': ['Northwind.example', 'ops.northwind.example'],
        'require_app_lock': true,
        'max_lock_minutes': 15,
        'no_export': false,
        'offline_hours': 72,
        'reauth_days': 30,
        'require_sso': false,
        'trusted_devices': true,
      },
      'records': {'history': true, 'activity': false, 'devices': true, 'ips': false},
      'crates': [
        {
          'name': 'Production',
          'owners_only': false,
          'allow': ['SFTP', 'forward'],
          'ask_again': true,
          'session_logs': true,
          'watched': false,
          'unwatched_away': true,
          'offline_hours': 24,
          'hosts': [
            {
              'name': 'web-1',
              'address': '10.50.0.11',
              'port': 2222,
              'protocol': 'SSH',
              'key': 'deploy',
              'group': 'Web',
              'tags': ['Prod', 'web'],
            },
            {'name': 'db-1', 'address': 'db-1.northwind.example', 'key': null, 'group': null},
          ],
        },
        {'name': 'Vault', 'owners_only': true},
      ],
      'roles': [
        {
          'name': 'Operators',
          'can': ['invite', 'create_crates'],
          'crates': {'Production': 'use+agent'},
        },
        {
          'name': 'Members',
          'can': <String>[],
          'crates': {
            'Production': ['connect', 'reveal'],
          },
        },
      ],
      'members': [
        {'email': ' Ada@Northwind.example ', 'role': 'Admin'},
        {
          'email': 'lin@northwind.example',
          'role': 'Operators',
          'crates': {'Production': 'manage'},
          'until': '2027-01-31T17:00:00Z',
        },
        {'email': 'sam@northwind.example', 'until': null, 'crates': <String, Object?>{}},
      ],
    };

    test('is read field by field', () {
      final file = _read(whole);
      expect(file.orchard, 'Northwind Ops');

      final rules = file.rules!;
      expect(rules.require2fa, isTrue);
      expect(rules.emailDomains, {'northwind.example', 'ops.northwind.example'});
      expect(rules.requireAppLock, isTrue);
      expect(rules.maxLockMinutes, 15);
      expect(rules.noExport, isFalse);
      expect(rules.offlineHours, 72);
      expect(rules.reauthDays, 30);
      expect(rules.requireSso, isFalse);
      expect(rules.trustedDevices, isTrue);

      final records = file.records!;
      expect(records.history, isTrue);
      expect(records.activity, isFalse);
      expect(records.devices, isTrue);
      expect(records.ips, isFalse);

      expect(file.crates!.map((c) => c.name), ['Production', 'Vault']);
      final production = file.crates![0];
      expect(production.ownersOnly, isFalse);
      expect(production.allow, {CrateSwitches.sftp, CrateSwitches.forward});
      expect(production.askAgain, isTrue);
      expect(production.sessionLogs, isTrue);
      expect(production.watched, isFalse);
      expect(production.unwatchedAway, isTrue);
      expect(production.offlineHours, 24);
      expect(production.hosts!.map((h) => h.name), ['web-1', 'db-1']);
      final web = production.hosts![0];
      expect(web.address, '10.50.0.11');
      expect(web.port, 2222);
      expect(web.protocol, 'ssh');
      expect(web.key, const Named<String?>('deploy'));
      expect(web.group, const Named<String?>('Web'));
      expect(web.tags, {'prod', 'web'});
      final db = production.hosts![1];
      expect(db.address, 'db-1.northwind.example');
      expect(db.port, isNull);
      expect(db.protocol, isNull);
      expect(db.key, const Named<String?>(null));
      expect(db.group, const Named<String?>(null));
      expect(db.tags, isNull);
      final vault = file.crates![1];
      expect(vault.ownersOnly, isTrue);
      expect(vault.allow, isNull);
      expect(vault.askAgain, isNull);
      expect(vault.sessionLogs, isNull);
      expect(vault.watched, isNull);
      expect(vault.unwatchedAway, isNull);
      expect(vault.offlineHours, isNull, reason: 'not named: left as it is');
      expect(vault.hosts, isNull);

      expect(file.roles!.map((r) => r.name), ['Operators', 'Members']);
      expect(file.roles![0].can, {RoleCan.invite, RoleCan.createCrates});
      expect(file.roles![0].crates, {
        'Production': {...levelSwitches(CrateLevel.use), CrateSwitches.agent},
      });
      expect(file.roles![1].can, isEmpty);
      expect(file.roles![1].crates, {
        'Production': {CrateSwitches.connect, CrateSwitches.reveal},
      });

      expect(file.members!.map((m) => m.email), [
        'ada@northwind.example',
        'lin@northwind.example',
        'sam@northwind.example',
      ]);
      final ada = file.members![0];
      expect(ada.role, 'admin');
      expect(ada.crates, isNull);
      expect(ada.until, isNull);
      final lin = file.members![1];
      expect(lin.role, 'Operators');
      expect(lin.crates, {'Production': levelSwitches(CrateLevel.manage)});
      expect(lin.until, Named<int?>(DateTime.utc(2027, 1, 31, 17).millisecondsSinceEpoch ~/ 1000));
      final sam = file.members![2];
      expect(sam.role, isNull);
      expect(sam.crates, isEmpty);
      expect(sam.until, const Named<int?>(null));
    });

    test('is written in one order, and reads back as the same file', () {
      final file = _read(whole);
      final text = writeSetupFile(file);
      expect(text, '''
{
  "zestssh_setup": 1,
  "orchard": "Northwind Ops",
  "rules": {
    "require_2fa": true,
    "email_domains": [
      "northwind.example",
      "ops.northwind.example"
    ],
    "require_app_lock": true,
    "max_lock_minutes": 15,
    "no_export": false,
    "offline_hours": 72,
    "reauth_days": 30,
    "require_sso": false,
    "trusted_devices": true
  },
  "records": {
    "history": true,
    "activity": false,
    "devices": true,
    "ips": false
  },
  "crates": [
    {
      "name": "Production",
      "owners_only": false,
      "allow": [
        "forward",
        "sftp"
      ],
      "ask_again": true,
      "session_logs": true,
      "watched": false,
      "unwatched_away": true,
      "offline_hours": 24,
      "hosts": [
        {
          "name": "web-1",
          "address": "10.50.0.11",
          "port": 2222,
          "protocol": "ssh",
          "key": "deploy",
          "group": "Web",
          "tags": [
            "prod",
            "web"
          ]
        },
        {
          "name": "db-1",
          "address": "db-1.northwind.example",
          "key": null,
          "group": null
        }
      ]
    },
    {
      "name": "Vault",
      "owners_only": true
    }
  ],
  "roles": [
    {
      "name": "Operators",
      "can": [
        "create_crates",
        "invite"
      ],
      "crates": {
        "Production": "use+agent"
      }
    },
    {
      "name": "Members",
      "can": [],
      "crates": {
        "Production": [
          "connect",
          "reveal"
        ]
      }
    }
  ],
  "members": [
    {
      "email": "ada@northwind.example",
      "role": "admin"
    },
    {
      "email": "lin@northwind.example",
      "role": "Operators",
      "crates": {
        "Production": "manage"
      },
      "until": "2027-01-31T17:00:00Z"
    },
    {
      "email": "sam@northwind.example",
      "crates": {},
      "until": null
    }
  ]
}
''');
      final again = readSetupFile(text);
      expect(again.problems, isEmpty);
      expect(writeSetupFile(again.file!), text);
    });
  });

  group('fields', () {
    test('one this version does not know is said, at every level, and never skipped', () {
      expect(
        _wrong({
          'crate': <Object?>[],
          'rules': {'require_2fa': true, 'require2fa': true},
          'records': {'histroy': true},
          'crates': [
            {
              'name': 'Production',
              'session_log': true,
              'hosts': [
                {'name': 'web-1', 'user': 'deploy'},
              ],
            },
          ],
          'roles': [
            {'name': 'Operators', 'rank': 5},
          ],
          'members': [
            {'email': 'ada@northwind.example', 'grants': <String, Object?>{}},
          ],
        }),
        [
          'unknownField crate',
          'unknownField rules.require2fa',
          'unknownField records.histroy',
          'unknownField crates[0].session_log',
          'unknownField crates[0].hosts[0].user',
          'unknownField roles[0].rank',
          'unknownField members[0].grants',
        ],
      );
    });

    test('one that would carry a secret is said as that', () {
      expect(
        _wrong({
          'Token': 'x',
          'crates': [
            {
              'name': 'Production',
              'secret': 'x',
              'hosts': [
                {'name': 'web-1', 'password': 'x', 'Passphrase': 'x', 'private_key': 'x', 'privateKey': 'x'},
                {'name': 'web-2', 'key_data': 'x', 'pin': '1'},
              ],
            },
          ],
        }),
        [
          'secretField Token',
          'secretField crates[0].secret',
          'secretField crates[0].hosts[0].password',
          'secretField crates[0].hosts[0].Passphrase',
          'secretField crates[0].hosts[0].private_key',
          'secretField crates[0].hosts[0].privateKey',
          'secretField crates[0].hosts[1].key_data',
          'secretField crates[0].hosts[1].pin',
        ],
      );
    });

    test('the same field twice in one object is said, wherever it is', () {
      const text = '''
{
  "zestssh_setup": 1,
  "orchard": "Northwind Ops",
  "crates": [
    {"name": "Production", "hosts": [], "hosts": [{"name": "web-1", "address": "10.50.0.11", "name": "web-2"}]},
    {"name": "Staging", "watched": true, "name": "Staging"}
  ],
  "orchard": "Northwind Ops",
  "rules": {"no_export": true, "no_export": true}
}
''';
      // (A field said twice is found where its second saying starts.)
      expect(duplicateFields(text), [
        'crates[0].hosts',
        'crates[0].hosts[0].name',
        'crates[1].name',
        'orchard',
        'rules.no_export',
      ]);
      expect(readSetupFile(text).problems.map((p) => '$p'), [
        'duplicateField crates[0].hosts',
        'duplicateField crates[0].hosts[0].name',
        'duplicateField crates[1].name',
        'duplicateField orchard',
        'duplicateField rules.no_export',
      ]);
    });

    test('a field spelled with an escape is the same field', () {
      final text = '{"zestssh_setup": 1, "orchard": "a", "orch${_bs}u0061rd": "b"}';
      expect(jsonDecode(text), {'zestssh_setup': 1, 'orchard': 'b'});
      expect(duplicateFields(text), ['orchard']);
      expect(readSetupFile(text).problems.map((p) => '$p'), ['duplicateField orchard']);
    });

    test('what a text holds is never taken for a field', () {
      // Braces, brackets, commas, colons and quotes inside values, and the
      // same field in different objects.
      final quote = '$_bs"';
      final text = '{"zestssh_setup": 1, "orchard": "a{b,$quote orchard$quote: [c]}", '
          '"crates": [{"name": "name"}, {"name": "x$_bs$_bs"}], '
          '"roles": [{"name": "a", "crates": {"name": "use"}}]}';
      expect(duplicateFields(text), isEmpty);
      final file = readSetupFile(text).file!;
      expect(file.orchard, 'a{b," orchard": [c]}');
      expect(file.crates!.map((c) => c.name), ['name', 'x$_bs']);
      expect(file.roles!.single.crates, {'name': levelSwitches(CrateLevel.use)});
    });

    test('a value of the wrong kind says which kind goes there', () {
      expect(
        _wrong({
          'orchard': 7,
          'rules': <Object?>[],
          'records': 'all',
          'crates': {'name': 'Production'},
          'roles': 'Operators',
          'members': 3,
        }),
        [
          'wrongKind orchard text',
          'wrongKind rules object',
          'wrongKind records object',
          'wrongKind crates list',
          'wrongKind roles list',
          'wrongKind members list',
        ],
      );
      expect(
        _wrong({
          'rules': {
            'require_2fa': 'yes',
            'email_domains': 'northwind.example',
            'max_lock_minutes': '15',
            'offline_hours': 1.5,
            'no_export': 1,
          },
          'records': {'history': 'on', 'ips': null},
          'crates': [
            'Production',
            {
              'name': 'Production',
              'owners_only': 'no',
              'allow': 'sftp',
              'ask_again': 0,
              'session_logs': 'true',
              'watched': null,
              'unwatched_away': 'yes',
              'offline_hours': '24',
              'hosts': {'name': 'web-1'},
            },
            {
              'name': 'Staging',
              'hosts': [
                7,
                {'name': 3},
                {'name': 'web-1', 'address': 5, 'port': '22', 'protocol': 7, 'key': 5, 'group': false, 'tags': 'web'},
                {
                  'name': 'web-2',
                  'tags': [3],
                },
              ],
            },
          ],
          'roles': [
            {
              'name': 'Operators',
              'can': 'invite',
              'crates': ['Production'],
            },
            {
              'name': 'Members',
              'crates': {'Production': 7, 'Staging': true},
            },
          ],
          'members': [
            {'email': 7},
            {'email': 'ada@northwind.example', 'role': 1, 'crates': 'all', 'until': 20270131},
          ],
        }),
        [
          'wrongKind rules.email_domains list',
          'wrongKind rules.require_2fa yesNo',
          'wrongKind rules.max_lock_minutes number',
          'wrongKind rules.no_export yesNo',
          'wrongKind rules.offline_hours number',
          'wrongKind records.history yesNo',
          'wrongKind records.ips yesNo',
          'wrongKind crates[0] object',
          'wrongKind crates[1].allow list',
          'wrongKind crates[1].watched yesNo',
          'wrongKind crates[1].owners_only yesNo',
          'wrongKind crates[1].ask_again yesNo',
          'wrongKind crates[1].session_logs yesNo',
          'wrongKind crates[1].unwatched_away yesNo',
          'wrongKind crates[1].offline_hours number',
          'wrongKind crates[1].hosts list',
          'wrongKind crates[2].hosts[0] object',
          'wrongKind crates[2].hosts[1].name text',
          'notOneOf crates[2].hosts[2].protocol et|ftps|ftps-implicit|mosh|sftp|ssh|telnet',
          'wrongKind crates[2].hosts[2].tags list',
          'wrongKind crates[2].hosts[2].address text',
          'wrongKind crates[2].hosts[2].port number',
          'wrongKind crates[2].hosts[2].key textOrNothing',
          'wrongKind crates[2].hosts[2].group textOrNothing',
          'wrongKind crates[2].hosts[3].tags[0] text',
          'wrongKind roles[0].can list',
          'wrongKind roles[0].crates object',
          'wrongKind roles[1].crates.Production level',
          'wrongKind roles[1].crates.Staging level',
          'notAnAddress members[0].email',
          'wrongKind members[1].role text',
          'notATime members[1].until',
          'wrongKind members[1].crates object',
        ],
      );
    });
  });

  group('names', () {
    test('are trimmed, and one with nothing in it is not a name', () {
      expect(
        _wrong({
          'orchard': '   ',
          'crates': [
            {'name': ''},
            {
              'name': 'Production',
              'hosts': [
                {'name': ' ', 'key': '', 'group': ' '},
                {'tags': <String>[]},
              ],
            },
            {'allow': <String>[]},
          ],
          'roles': [
            {'name': ''},
            {'can': <String>[]},
          ],
          'members': [
            {'role': 'admin'},
            {'email': 'ada@northwind.example', 'role': ''},
          ],
        }),
        [
          'empty orchard',
          'empty crates[0].name',
          'empty crates[1].hosts[0].name',
          'empty crates[1].hosts[0].key',
          'empty crates[1].hosts[0].group',
          'missing crates[1].hosts[1].name',
          'missing crates[2].name',
          'empty roles[0].name',
          'missing roles[1].name',
          'missing members[0].email',
          'empty members[1].role',
        ],
      );
      final file = _read({
        'crates': [
          {
            'name': '  Production ',
            'hosts': [
              {'name': ' web-1 ', 'address': ' 10.50.0.11 ', 'key': ' deploy ', 'group': ' Web ', 'tags': [' Prod ']},
            ],
          },
        ],
        'roles': [
          {'name': ' Operators ', 'crates': {' Production ': ' Use '}},
        ],
        'members': [
          {'email': 'ada@northwind.example', 'role': ' Operators '},
        ],
      });
      expect(file.crates!.single.name, 'Production');
      final host = file.crates!.single.hosts!.single;
      expect(host.name, 'web-1');
      expect(host.address, '10.50.0.11');
      expect(host.key!.value, 'deploy');
      expect(host.group!.value, 'Web');
      expect(host.tags, {'prod'});
      expect(file.roles!.single.name, 'Operators');
      expect(file.roles!.single.crates, {'Production': levelSwitches(CrateLevel.use)});
      expect(file.members!.single.role, 'Operators');
    });

    test('are no longer than the app takes them', () {
      String long(int n) => 'a' * n;
      // Counted in characters, not in what they take to store.
      final wide = String.fromCharCode(0x1f34a) * kSetupMaxSpaceName;
      _read({
        'orchard': long(kSetupMaxSpaceName),
        'crates': [
          {
            'name': wide,
            'hosts': [
              {
                'name': long(kSetupMaxItemName),
                'address': long(kSetupMaxItemName),
                'key': long(kSetupMaxItemName),
                'group': long(kSetupMaxItemName),
                'tags': [long(kSetupMaxTag)],
              },
            ],
          },
        ],
        'roles': [
          {'name': long(kSetupMaxSpaceName), 'crates': {long(kSetupMaxSpaceName): 'use'}},
        ],
        'members': [
          {'email': 'ada@northwind.example', 'role': long(kSetupMaxSpaceName)},
        ],
      });
      expect(
        _wrong({
          'orchard': long(kSetupMaxSpaceName + 1),
          'crates': [
            {
              'name': '$wide!',
              'hosts': [
                {
                  'name': long(kSetupMaxItemName + 1),
                  'address': long(kSetupMaxItemName + 1),
                  'key': long(kSetupMaxItemName + 1),
                  'group': long(kSetupMaxItemName + 1),
                  'tags': [long(kSetupMaxTag + 1)],
                },
              ],
            },
          ],
          'roles': [
            {'name': long(kSetupMaxSpaceName + 1), 'crates': {long(kSetupMaxSpaceName + 1): 'use'}},
          ],
          'members': [
            {'email': 'ada@northwind.example', 'role': long(kSetupMaxSpaceName + 1)},
          ],
        }),
        [
          'tooLong orchard max 50',
          'tooLong crates[0].name max 50',
          'tooLong crates[0].hosts[0].name max 255',
          'tooLong crates[0].hosts[0].tags[0] max 32',
          'tooLong crates[0].hosts[0].address max 255',
          'tooLong crates[0].hosts[0].key max 255',
          'tooLong crates[0].hosts[0].group max 255',
          'tooLong roles[0].name max 50',
          'tooLong roles[0].crates.${long(kSetupMaxSpaceName + 1)} max 50',
          'tooLong members[0].role max 50',
        ],
      );
    });

    test('hold no character that does not show or that turns the reading around', () {
      // The first and last of each range, and the two marks on their own.
      for (final code in [0x00, 0x09, 0x1f, 0x7f, 0x9f, 0x200e, 0x200f, 0x202a, 0x202e, 0x2066, 0x2069]) {
        final name = 'Pro${String.fromCharCode(code)}duction';
        expect(
          _wrong({
            'crates': [
              {'name': name},
            ],
          }),
          ['oddCharacters crates[0].name'],
          reason: 'U+${code.toRadixString(16)}',
        );
      }
      // Their neighbours are ordinary characters.
      for (final code in [0x20, 0x7e, 0xa0, 0x200d, 0x2010, 0x2027, 0x202f, 0x205f, 0x2070, 0x1f34a]) {
        final name = 'Pro${String.fromCharCode(code)}duction';
        expect(
            _read({
              'crates': [
                {'name': name},
              ],
            }).crates!.single.name,
            name,
            reason: 'U+${code.toRadixString(16)}');
      }
      expect(
        _wrong({
          'orchard': 'North${String.fromCharCode(0x202e)}wind',
          'crates': [
            {
              'name': 'Production',
              'hosts': [
                {
                  'name': 'web${String.fromCharCode(10)}1',
                  'address': '10.50.0.11 10.50.0.12',
                  'key': 'de${String.fromCharCode(0x200f)}ploy',
                  'group': 'W${String.fromCharCode(0x2066)}eb',
                  'tags': ['pr${String.fromCharCode(0x7f)}od'],
                },
              ],
            },
          ],
          'roles': [
            {'name': 'Oper${String.fromCharCode(0x202a)}ators', 'crates': {'Pro${String.fromCharCode(1)}d': 'use'}},
          ],
          'members': [
            {'email': 'ada@northwind.example', 'role': 'Oper${String.fromCharCode(0x2069)}ators'},
          ],
        }),
        [
          'oddCharacters orchard',
          'oddCharacters crates[0].hosts[0].name',
          'oddCharacters crates[0].hosts[0].tags[0]',
          'oddCharacters crates[0].hosts[0].address',
          'oddCharacters crates[0].hosts[0].key',
          'oddCharacters crates[0].hosts[0].group',
          'oddCharacters roles[0].name',
          'oddCharacters roles[0].crates.Pro${String.fromCharCode(1)}d',
          'oddCharacters members[0].role',
        ],
      );
    });

    test('stand for one thing each: the same one twice is said', () {
      expect(
        _wrong({
          'crates': [
            {
              'name': 'Production',
              'hosts': [
                {'name': 'web-1'},
                {'name': 'Web-1 '},
                {'name': 'web-2'},
              ],
            },
            {
              'name': ' production',
              'hosts': [
                {'name': 'web-1'},
              ],
            },
            // The same host name in another Crate is another host.
            {
              'name': 'Staging',
              'hosts': [
                {'name': 'web-1'},
              ],
            },
          ],
          'roles': [
            {'name': 'Operators', 'crates': {'Production': 'use', 'PRODUCTION': 'edit', 'Staging': 'use'}},
            {'name': 'operators'},
          ],
          'members': [
            {'email': 'ada@northwind.example', 'crates': {'Staging': 'use', 'staging ': 'use'}},
            {'email': 'ADA@northwind.example'},
          ],
        }),
        [
          'duplicate crates[0].hosts[1].name Web-1',
          'duplicate crates[1].name production',
          'duplicate roles[0].crates.PRODUCTION PRODUCTION',
          'duplicate roles[1].name operators',
          'duplicate members[0].crates.staging  staging',
          'duplicate members[1].email ada@northwind.example',
        ],
      );
    });

    test("a role is not called what the Orchard's own two are, and a member's role written so means them", () {
      expect(
        _wrong({
          'roles': [
            {'name': 'owner'},
            {'name': ' Admin '},
            {'name': 'OWNER', 'can': 'x'},
            {'name': 'Owners'},
          ],
        }),
        [
          'reservedRole roles[0].name owner',
          'reservedRole roles[1].name Admin',
          'reservedRole roles[2].name OWNER',
          'wrongKind roles[2].can list',
        ],
      );
      final file = _read({
        'members': [
          {'email': 'ada@northwind.example', 'role': 'Owner'},
          {'email': 'lin@northwind.example', 'role': ' ADMIN '},
          {'email': 'sam@northwind.example', 'role': 'Admins'},
        ],
      });
      expect(file.members!.map((m) => m.role), ['owner', 'admin', 'Admins']);
      expect(isFixedRoleName('owner'), isTrue);
      expect(isFixedRoleName(' Admin'), isTrue);
      expect(isFixedRoleName('owners'), isFalse);
      expect(isFixedRoleName('administrator'), isFalse);
    });
  });

  group('lists', () {
    test('hold no more than an Orchard may', () {
      List<Map<String, Object?>> named(int n, String field, String Function(int) of) =>
          [for (var i = 0; i < n; i++) {field: of(i)}];
      _read({
        'crates': [
          {'name': 'Production', 'hosts': named(kSetupMaxHosts, 'name', (i) => 'web-$i')},
          ...named(kSetupMaxCrates - 1, 'name', (i) => 'Crate $i'),
        ],
        'roles': named(kSetupMaxRoles, 'name', (i) => 'Role $i'),
        'members': named(kSetupMaxMembers, 'email', (i) => 'member$i@northwind.example'),
        'rules': {
          'email_domains': [for (var i = 0; i < kMaxRuleDomains; i++) 'd$i.example'],
        },
      });
      expect(
        _wrong({
          'crates': named(kSetupMaxCrates + 1, 'name', (i) => 'Crate $i'),
          'roles': named(kSetupMaxRoles + 1, 'name', (i) => 'Role $i'),
          'members': named(kSetupMaxMembers + 1, 'email', (i) => 'member$i@northwind.example'),
          'rules': {
            'email_domains': [for (var i = 0; i <= kMaxRuleDomains; i++) 'd$i.example'],
          },
        }),
        [
          'tooMany rules.email_domains max 20',
          'tooMany crates max 200',
          'tooMany roles max 30',
          'tooMany members max 2000',
        ],
      );
      expect(
        _wrong({
          'crates': [
            {
              'name': 'Production',
              'hosts': [
                ...named(kSetupMaxHosts, 'name', (i) => 'web-$i'),
                {'name': 'one more'},
              ],
            },
            {
              'name': 'Staging',
              'hosts': [
                {'name': 'web-1', 'tags': [for (var i = 0; i <= kSetupMaxTags; i++) 't$i']},
                {'name': 'web-2', 'tags': [for (var i = 0; i < kSetupMaxTags; i++) 't$i']},
              ],
            },
          ],
          'roles': [
            {'name': 'Operators', 'crates': {for (var i = 0; i <= kSetupMaxCrates; i++) 'Crate $i': 'use'}},
          ],
        }),
        [
          'tooMany crates[0].hosts max 2000',
          'tooMany crates[1].hosts[0].tags max 20',
          'tooMany roles[0].crates max 200',
        ],
      );
    });
  });

  group('rules and what the team records', () {
    test('who connects to a watched Crate while ZestSSH Cloud cannot be reached is a yes or a no, or left as it '
        'is', () {
      final read = _read({
        'crates': [
          {'name': 'A', 'unwatched_away': true},
          {'name': 'B', 'unwatched_away': false},
          {'name': 'C'},
        ],
      });
      expect(read.crates!.map((c) => c.unwatchedAway), [true, false, null]);
      expect(read.crates!.map((c) => c.toJson()), [
        {'name': 'A', 'unwatched_away': true},
        {'name': 'B', 'unwatched_away': false},
        {'name': 'C'},
      ]);
      expect(
        _wrong({
          'crates': [
            {'name': 'A', 'unwatched_away': 1},
            {'name': 'B', 'unwatched_away': 'everyone'},
          ],
        }),
        ['wrongKind crates[0].unwatched_away yesNo', 'wrongKind crates[1].unwatched_away yesNo'],
      );
      // A name for it that the file does not know is said, not passed over.
      expect(
        _wrong({
          'crates': [
            {'name': 'A', 'unwatched': true},
          ],
        }),
        hasLength(1),
      );
    });

    test("a Crate's own offline limit stays within a year, and none is 0", () {
      final read = _read({
        'crates': [
          {'name': 'A', 'offline_hours': 0},
          {'name': 'B', 'offline_hours': 8760},
          {'name': 'C'},
        ],
      });
      expect(read.crates!.map((c) => c.offlineHours), [0, 8760, null]);
      expect(
        _wrong({
          'crates': [
            {'name': 'A', 'offline_hours': 8761},
            {'name': 'B', 'offline_hours': -1},
            {'name': 'C', 'offline_hours': 1.5},
          ],
        }),
        [
          'outOfRange crates[0].offline_hours min 0 max 8760',
          'outOfRange crates[1].offline_hours min 0 max 8760',
          'wrongKind crates[2].offline_hours number',
        ],
      );
      // A name for it that the file does not know is said, not passed over.
      expect(
        _wrong({
          'crates': [
            {'name': 'A', 'offline_limit': 24},
          ],
        }),
        hasLength(1),
      );
    });

    test('numbers stay within what a rule may be', () {
      _read({
        'rules': {'max_lock_minutes': 0, 'offline_hours': 0, 'reauth_days': 0},
      });
      _read({
        'rules': {'max_lock_minutes': 1440, 'offline_hours': 8760, 'reauth_days': 365},
      });
      expect(
        _wrong({
          'rules': {'max_lock_minutes': 1441, 'offline_hours': 8761, 'reauth_days': 366},
        }),
        [
          'outOfRange rules.max_lock_minutes min 0 max 1440',
          'outOfRange rules.offline_hours min 0 max 8760',
          'outOfRange rules.reauth_days min 0 max 365',
        ],
      );
      expect(
        _wrong({
          'rules': {'max_lock_minutes': -1, 'offline_hours': -1, 'reauth_days': -1},
        }),
        [
          'outOfRange rules.max_lock_minutes min 0 max 1440',
          'outOfRange rules.offline_hours min 0 max 8760',
          'outOfRange rules.reauth_days min 0 max 365',
        ],
      );
    });

    test('a domain is one a rule can name; said twice it counts once', () {
      expect(
        _read({
          'rules': {
            'email_domains': [' Northwind.Example ', 'northwind.example', 'ops.northwind.example'],
          },
        }).rules!.emailDomains,
        {'northwind.example', 'ops.northwind.example'},
      );
      expect(_read({'rules': {'email_domains': <String>[]}}).rules!.emailDomains, isEmpty);
      expect(
        _wrong({
          'rules': {
            'email_domains': ['northwind', 'ada@northwind.example', 7, 'northwind.example', '-x.example'],
          },
        }),
        [
          'notADomain rules.email_domains[0]',
          'notADomain rules.email_domains[1]',
          'notADomain rules.email_domains[2]',
          'notADomain rules.email_domains[4]',
        ],
      );
    });

    test('what a file names goes over what is; the rest stays', () {
      const now = RecordRules(
        require2fa: true,
        emailDomains: {'northwind.example'},
        requireAppLock: true,
        maxLockMinutes: 30,
        noExport: true,
        offlineHours: 48,
        reauthDays: 14,
        requireSso: true,
        trustedDevices: true,
      );
      // Nothing named: nothing changes.
      final same = const SetupRules().over(now);
      expect(same.toBody(), now.toBody());
      // Each rule by itself.
      expect(const SetupRules(require2fa: false).over(now).toBody(), now.copyWith(require2fa: false).toBody());
      expect(const SetupRules(emailDomains: {}).over(now).toBody(), now.copyWith(emailDomains: {}).toBody());
      expect(const SetupRules(requireAppLock: false).over(now).toBody(), now.copyWith(requireAppLock: false).toBody());
      expect(const SetupRules(maxLockMinutes: 5).over(now).toBody(), now.copyWith(maxLockMinutes: 5).toBody());
      expect(const SetupRules(noExport: false).over(now).toBody(), now.copyWith(noExport: false).toBody());
      expect(const SetupRules(offlineHours: 0).over(now).toBody(), now.copyWith(offlineHours: 0).toBody());
      expect(const SetupRules(reauthDays: 90).over(now).toBody(), now.copyWith(reauthDays: 90).toBody());
      expect(const SetupRules(requireSso: false).over(now).toBody(), now.copyWith(requireSso: false).toBody());
      expect(const SetupRules(trustedDevices: false).over(now).toBody(), now.copyWith(trustedDevices: false).toBody());
      // The two about remote screens (4.0): set, and cleared.
      expect(const SetupRules(screensSshOnly: true, screensLockRedirections: true).over(now).toBody(),
          now.copyWith(screensSshOnly: true, screensLockRedirections: true).toBody());
      const screens = RecordRules(screensSshOnly: true, screensLockRedirections: true);
      expect(const SetupRules(screensSshOnly: false).over(screens).toBody(),
          const RecordRules(screensLockRedirections: true).toBody());
      expect(const SetupRules().over(screens).toBody(), screens.toBody(), reason: 'not named: as they are');
      // All of them named is those rules, whatever was.
      expect(SetupRules.of(now).over(RecordRules.none).toBody(), now.toBody());
      expect(SetupRules.of(RecordRules.none).over(now).toBody(), RecordRules.none.toBody());
      // A copy of its own: changing the file's domains later changes no rule.
      final named = SetupRules.of(now);
      final rules = named.over(RecordRules.none);
      named.emailDomains!.add('other.example');
      expect(rules.emailDomains, {'northwind.example'});
      expect(now.emailDomains, {'northwind.example'});

      const recorded = RecordTracking(history: true, activity: true, devices: true, ips: true);
      expect(const SetupRecords().over(recorded), recorded);
      expect(const SetupRecords(history: false).over(recorded), recorded.copyWith(history: false));
      expect(const SetupRecords(activity: false).over(recorded), recorded.copyWith(activity: false));
      expect(const SetupRecords(devices: false).over(recorded), recorded.copyWith(devices: false));
      expect(const SetupRecords(ips: false).over(recorded), recorded.copyWith(ips: false));
      expect(SetupRecords.of(recorded).over(RecordTracking.none), recorded);
      expect(SetupRecords.of(RecordTracking.none).over(recorded), RecordTracking.none);
    });

    test('every rule and every record is written under its own name', () {
      const rules = RecordRules(
        require2fa: true,
        emailDomains: {'ops.northwind.example', 'northwind.example'},
        requireAppLock: true,
        maxLockMinutes: 30,
        noExport: true,
        offlineHours: 48,
        reauthDays: 14,
        requireSso: true,
        trustedDevices: true,
      );
      expect(SetupRules.of(rules).toJson(), {
        'require_2fa': true,
        'email_domains': ['northwind.example', 'ops.northwind.example'],
        'require_app_lock': true,
        'max_lock_minutes': 30,
        'no_export': true,
        'offline_hours': 48,
        'reauth_days': 14,
        'require_sso': true,
        'trusted_devices': true,
      });
      expect(SetupRules.of(RecordRules.none).toJson(), {
        'require_2fa': false,
        'email_domains': <String>[],
        'require_app_lock': false,
        'max_lock_minutes': 0,
        'no_export': false,
        'offline_hours': 0,
        'reauth_days': 0,
        'require_sso': false,
        'trusted_devices': false,
      });
      expect(const SetupRules().toJson(), isEmpty);
      // The two about remote screens are named only while on (the file of a team without them
      // is read by apps from before remote screens), and by their own names.
      final screens = SetupRules.of(const RecordRules(screensSshOnly: true, screensLockRedirections: true)).toJson();
      expect((screens['screens_ssh_only'], screens['screens_lock_redirections']), (true, true));
      final one = SetupRules.of(const RecordRules(screensLockRedirections: true)).toJson();
      expect(one.containsKey('screens_ssh_only'), isFalse);
      expect(one['screens_lock_redirections'], true);
      expect(SetupRecords.of(const RecordTracking(history: true, devices: true)).toJson(),
          {'history': true, 'activity': false, 'devices': true, 'ips': false});
      expect(SetupRecords.of(const RecordTracking(activity: true, ips: true)).toJson(),
          {'history': false, 'activity': true, 'devices': false, 'ips': true});
      expect(const SetupRecords().toJson(), isEmpty);
      // Each record read under its own name, too.
      for (final field in ['history', 'activity', 'devices', 'ips']) {
        final records = _read({
          'records': {field: true},
        }).records!;
        expect(records.toJson(), {field: true});
      }
      for (final field in [
        'require_2fa',
        'require_app_lock',
        'no_export',
        'require_sso',
        'trusted_devices',
        'screens_ssh_only',
        'screens_lock_redirections',
      ]) {
        expect(_read({'rules': {field: true}}).rules!.toJson(), {field: true});
        expect(_read({'rules': {field: false}}).rules!.toJson(), {field: false});
      }
      for (final field in ['max_lock_minutes', 'offline_hours', 'reauth_days']) {
        expect(_read({'rules': {field: 7}}).rules!.toJson(), {field: 7});
      }
    });
  });

  group('Crates and hosts', () {
    test('what a Crate allows is some of SFTP, port forwarding and agent forwarding', () {
      expect(
        _read({
          'crates': [
            {'name': 'A', 'allow': ['Agent', ' sftp ', 'forward', 'sftp']},
            {'name': 'B', 'allow': <String>[]},
          ],
        }).crates!.map((c) => c.allow),
        [
          {CrateSwitches.agent, CrateSwitches.sftp, CrateSwitches.forward},
          <String>{},
        ],
      );
      expect(
        _wrong({
          'crates': [
            {'name': 'A', 'allow': ['sftp', 'connect', 7, 'ports']},
          ],
        }),
        [
          'notOneOf crates[0].allow[1] agent|forward|sftp',
          'notOneOf crates[0].allow[2] agent|forward|sftp',
          'notOneOf crates[0].allow[3] agent|forward|sftp',
        ],
      );
    });

    test('a Crate named as watched allows nothing; one named as not watched may', () {
      expect(
        _wrong({
          'crates': [
            {'name': 'A', 'watched': true, 'allow': ['sftp']},
          ],
        }),
        ['watchedAllows crates[0].allow'],
      );
      final file = _read({
        'crates': [
          {'name': 'A', 'watched': true, 'allow': <String>[]},
          {'name': 'B', 'watched': true},
          {'name': 'C', 'watched': false, 'allow': ['sftp']},
          {'name': 'D', 'allow': ['sftp']},
        ],
      });
      expect(file.crates!.map((c) => c.watched), [true, true, false, null]);
    });

    test('a port is a port, and a protocol one that goes to an address', () {
      final file = _read({
        'crates': [
          {
            'name': 'A',
            'hosts': [
              {'name': 'a', 'port': 1, 'protocol': 'ssh'},
              {'name': 'b', 'port': 65535, 'protocol': 'Mosh'},
              {'name': 'c', 'protocol': 'et'},
              {'name': 'd', 'protocol': ' telnet '},
              // A host that is SFTP only (files, no terminal).
              {'name': 'e', 'protocol': 'SFTP'},
            ],
          },
        ],
      });
      expect(file.crates!.single.hosts!.map((h) => h.port), [1, 65535, null, null, null]);
      expect(file.crates!.single.hosts!.map((h) => h.protocol), ['ssh', 'mosh', 'et', 'telnet', 'sftp']);
      expect(kSetupProtocols, {'ssh', 'sftp', 'mosh', 'et', 'telnet', 'ftps', 'ftps-implicit'});
      expect(
        _wrong({
          'crates': [
            {
              'name': 'A',
              'hosts': [
                {'name': 'a', 'port': 0},
                {'name': 'b', 'port': 65536},
                {'name': 'c', 'protocol': 'serial'},
                {'name': 'd', 'protocol': 'localShell'},
                {'name': 'e', 'protocol': 'demo'},
                {'name': 'f', 'protocol': ''},
                {'name': 'g', 'protocol': 'ftpsImplicit'},
                {'name': 'h', 'protocol': 'ftp'},
              ],
            },
          ],
        }),
        [
          'outOfRange crates[0].hosts[0].port min 1 max 65535',
          'outOfRange crates[0].hosts[1].port min 1 max 65535',
          'notOneOf crates[0].hosts[2].protocol et|ftps|ftps-implicit|mosh|sftp|ssh|telnet',
          'notOneOf crates[0].hosts[3].protocol et|ftps|ftps-implicit|mosh|sftp|ssh|telnet',
          'notOneOf crates[0].hosts[4].protocol et|ftps|ftps-implicit|mosh|sftp|ssh|telnet',
          'notOneOf crates[0].hosts[5].protocol et|ftps|ftps-implicit|mosh|sftp|ssh|telnet',
          'notOneOf crates[0].hosts[6].protocol et|ftps|ftps-implicit|mosh|sftp|ssh|telnet',
          'notOneOf crates[0].hosts[7].protocol et|ftps|ftps-implicit|mosh|sftp|ssh|telnet',
        ],
      );
    });

    test('a protocol this version does not know is refused where it stands, as a version from before sftp refuses '
        'sftp: the place names the host by its place in the file, and says what is taken', () {
      final problems = _wrong({
        'crates': [
          {
            'name': 'Production',
            'hosts': [
              {'name': 'db-primary', 'address': '192.0.2.10'},
              {'name': 'files-01', 'address': '192.0.2.20', 'protocol': 'ftp'},
            ],
          },
        ],
      });
      expect(problems, ['notOneOf crates[0].hosts[1].protocol et|ftps|ftps-implicit|mosh|sftp|ssh|telnet']);
    });

    test('a key and a group are named, named as none, or left out', () {
      final hosts = _read({
        'crates': [
          {
            'name': 'A',
            'hosts': [
              {'name': 'a', 'key': 'deploy', 'group': 'Web'},
              {'name': 'b', 'key': null, 'group': null},
              {'name': 'c'},
            ],
          },
        ],
      }).crates!.single.hosts!;
      expect(hosts[0].key, const Named<String?>('deploy'));
      expect(hosts[0].group, const Named<String?>('Web'));
      expect(hosts[1].key, const Named<String?>(null));
      expect(hosts[1].group, const Named<String?>(null));
      expect(hosts[2].key, isNull);
      expect(hosts[2].group, isNull);
      expect(hosts[0].toJson(), {'name': 'a', 'key': 'deploy', 'group': 'Web'});
      expect(hosts[1].toJson(), {'name': 'b', 'key': null, 'group': null});
      expect(hosts[2].toJson(), {'name': 'c'});
      // What a value names is told apart from another, and from none.
      expect(const Named<String?>('deploy') == const Named<String?>('deploy'), isTrue);
      expect(const Named<String?>('deploy') == const Named<String?>('other'), isFalse);
      expect(const Named<String?>('deploy') == const Named<String?>(null), isFalse);
      expect(const Named<String?>('deploy').hashCode, const Named<String?>('deploy').hashCode);
      expect('${const Named<String?>('deploy')}', 'Named(deploy)');
    });
  });

  group('what someone may do in a Crate', () {
    test('is a level by name, with agent forwarding on top, or the switches themselves', () {
      Set<String> of(Object? v) => _read({
            'roles': [
              {
                'name': 'R',
                'crates': {'A': v},
              },
            ],
          }).roles!.single.crates!['A']!;
      for (final level in CrateLevel.values) {
        expect(of(level.name), levelSwitches(level), reason: level.name);
        expect(of(' ${level.name.toUpperCase()}+Agent '), {...levelSwitches(level), CrateSwitches.agent},
            reason: level.name);
      }
      expect(of(['connect']), {CrateSwitches.connect});
      expect(of([' Reveal ', 'CONNECT', 'connect', 'agent']),
          {CrateSwitches.reveal, CrateSwitches.connect, CrateSwitches.agent});
      expect(of(CrateSwitches.all.toList()), CrateSwitches.all);
    });

    test('names a level there is, and never leaves Connect out', () {
      List<String> wrong(Object? v) => _wrong({
            'members': [
              {
                'email': 'ada@northwind.example',
                'crates': {'A': v},
              },
            ],
          });
      const levels = 'connect|use|edit|manage|connect+agent|use+agent|edit+agent|manage+agent';
      expect(wrong('admin'), ['notOneOf members[0].crates.A $levels']);
      expect(wrong(''), ['notOneOf members[0].crates.A $levels']);
      expect(wrong('use+sftp'), ['notOneOf members[0].crates.A $levels']);
      expect(wrong('+agent'), ['notOneOf members[0].crates.A $levels']);
      expect(wrong('use+agent+agent'), ['notOneOf members[0].crates.A $levels']);
      final all = (CrateSwitches.all.toList()..sort()).join('|');
      expect(wrong(['connect', 'write', 7]), [
        'notOneOf members[0].crates.A[1] $all',
        'notOneOf members[0].crates.A[2] $all',
      ]);
      expect(wrong(['reveal', 'sftp']), ['needsConnect members[0].crates.A']);
      expect(wrong(<String>[]), ['needsConnect members[0].crates.A']);
    });

    test('is written as the level it is exactly, else as its switches', () {
      for (final level in CrateLevel.values) {
        expect(switchesJson(levelSwitches(level)), level.name);
        expect(switchesJson({...levelSwitches(level), CrateSwitches.agent}), '${level.name}+agent');
      }
      // One switch more or less than a level is no level.
      expect(switchesJson({CrateSwitches.connect}), ['connect']);
      expect(switchesJson({...levelSwitches(CrateLevel.use)}..remove(CrateSwitches.sftp)),
          ['connect', 'forward', 'reveal']);
      expect(switchesJson({...levelSwitches(CrateLevel.connect), CrateSwitches.add}),
          ['add', 'connect', 'forward', 'sftp']);
      expect(switchesJson({CrateSwitches.connect, CrateSwitches.agent}), ['agent', 'connect']);
      // Whatever it is written as reads back as the same switches.
      for (final switches in [
        {CrateSwitches.connect},
        {...levelSwitches(CrateLevel.edit), CrateSwitches.agent},
        {CrateSwitches.connect, CrateSwitches.manage},
        CrateSwitches.all,
      ]) {
        final text = writeSetupFile(SetupFile(roles: [
          SetupRole(name: 'R', crates: {'A': switches}),
        ]));
        expect(readSetupFile(text).file!.roles!.single.crates!['A'], switches);
      }
    });

    test('what a role may do in the Orchard is some of four things', () {
      expect(
        _read({
          'roles': [
            {'name': 'R', 'can': ['Invite', 'remove', ' change_roles ', 'create_crates', 'invite']},
          ],
        }).roles!.single.can,
        RoleCan.all,
      );
      final all = (RoleCan.all.toList()..sort()).join('|');
      expect(
        _wrong({
          'roles': [
            {'name': 'R', 'can': ['invite', 'manage', 3]},
          ],
        }),
        ['notOneOf roles[0].can[1] $all', 'notOneOf roles[0].can[2] $all'],
      );
    });
  });

  group('members', () {
    test('are named by an address ZestSSH Cloud would take', () {
      expect(
        _read({
          'members': [
            {'email': 'a@b.example'},
            {'email': "o'neil+ops@sub.north-wind.example"},
            {'email': ' UPPER@Northwind.Example '},
          ],
        }).members!.map((m) => m.email),
        ['a@b.example', "o'neil+ops@sub.north-wind.example", 'upper@northwind.example'],
      );
      expect(
        _wrong({
          'members': [
            {'email': 'ada'},
            {'email': 'ada@northwind'},
            {'email': '@northwind.example'},
            {'email': 'ada lin@northwind.example'},
            {'email': 'ada@north_wind.example'},
            {'email': ''},
            {'email': '${'a' * 310}@northwind.example'},
            {'email': null},
          ],
        }),
        [for (var i = 0; i < 8; i++) 'notAnAddress members[$i].email'],
      );
      // The longest address there can be.
      final longest = '${'a' * (kSetupMaxAddress - 18)}@northwind.example';
      expect(longest.length, kSetupMaxAddress);
      expect(_read({'members': [{'email': longest}]}).members!.single.email, longest);
    });

    test('a time says its zone, and is a moment that exists', () {
      int at(String text) => _read({
            'members': [
              {'email': 'ada@northwind.example', 'until': text},
            ],
          }).members!.single.until!.value!;
      int utc(int y, int mo, int d, [int h = 0, int mi = 0, int s = 0]) =>
          DateTime.utc(y, mo, d, h, mi, s).millisecondsSinceEpoch ~/ 1000;
      expect(at('2027-01-31T17:00:00Z'), utc(2027, 1, 31, 17));
      expect(at('2027-01-31T17:00Z'), utc(2027, 1, 31, 17));
      expect(at(' 2027-01-31T17:04:05Z '), utc(2027, 1, 31, 17, 4, 5));
      expect(at('2027-01-31T17:00:00+02:00'), utc(2027, 1, 31, 15));
      expect(at('2027-01-31T17:00:00-05:30'), utc(2027, 1, 31, 22, 30));
      expect(at('2027-01-01T00:30:00+01:00'), utc(2026, 12, 31, 23, 30));
      expect(at('2028-02-29T23:59:59Z'), utc(2028, 2, 29, 23, 59, 59));
      expect(at('2027-12-31T23:59:59+00:00'), utc(2027, 12, 31, 23, 59, 59));
      expect(at('1970-01-01T00:00:01Z'), 1);
      expect(at('2027-06-30T12:00:00+23:59'), utc(2027, 6, 29, 12, 1));

      for (final text in [
        '2027-01-31',
        '2027-01-31T17:00:00',
        '2027-01-31 17:00:00Z',
        '2027-01-31T17:00:00.5Z',
        '2027-01-31T17:00:00z',
        '2027-02-29T00:00:00Z',
        '2027-04-31T00:00:00Z',
        '2027-00-10T00:00:00Z',
        '2027-13-10T00:00:00Z',
        '2027-01-00T00:00:00Z',
        '2027-01-32T00:00:00Z',
        '2027-01-31T24:00:00Z',
        '2027-01-31T17:60:00Z',
        '2027-01-31T17:00:60Z',
        '2027-01-31T17:00:00+24:00',
        '2027-01-31T17:00:00+02:60',
        '2027-01-31T17:00:00+0200',
        '1969-12-31T23:59:59Z',
        '1970-01-01T00:00:00Z',
        '1970-01-01T00:30:00+01:00',
        'tomorrow',
        '',
      ]) {
        expect(parseSetupTime(text), isNull, reason: text);
        expect(
          _wrong({
            'members': [
              {'email': 'ada@northwind.example', 'until': text},
            ],
          }),
          ['notATime members[0].until'],
          reason: text,
        );
      }
    });

    test('a time is written in UTC to the second, and reads back as itself', () {
      expect(setupTime(1), '1970-01-01T00:00:01Z');
      expect(setupTime(DateTime.utc(2027, 1, 31, 17).millisecondsSinceEpoch ~/ 1000), '2027-01-31T17:00:00Z');
      expect(setupTime(DateTime.utc(2027, 11, 9, 8, 7, 6).millisecondsSinceEpoch ~/ 1000), '2027-11-09T08:07:06Z');
      for (final seconds in [1, 59, 86399, 86400, 1798736400, 1830297599, 4102444800]) {
        expect(parseSetupTime(setupTime(seconds)), seconds);
      }
      expect(
          const SetupMember(email: 'ada@northwind.example', until: Named(1798736400)).toJson()['until'],
          '2026-12-31T17:00:00Z');
      final none = const SetupMember(email: 'ada@northwind.example', until: Named<int?>(null)).toJson();
      expect(none.containsKey('until'), isTrue);
      expect(none['until'], isNull);
      expect(const SetupMember(email: 'ada@northwind.example').toJson().containsKey('until'), isFalse);
    });
  });

  group("a member's limits", () {
    test('are a level by name, with agent forwarding, the switches, or No access as none or no switches', () {
      final ada = _read({
        'members': [
          {
            'email': 'ada@northwind.example',
            'limits': {
              'Production': 'connect',
              'Staging': ' Use+Agent ',
              'Lab': ['connect', 'reveal'],
              'Vault': 'none',
              'Depot': ' NONE ',
              'Edge': <String>[],
            },
          },
        ],
      }).members!.single;
      expect(ada.limits, {
        'Production': levelSwitches(CrateLevel.connect),
        'Staging': {...levelSwitches(CrateLevel.use), CrateSwitches.agent},
        'Lab': {CrateSwitches.connect, CrateSwitches.reveal},
        'Vault': <String>{},
        'Depot': <String>{},
        'Edge': <String>{},
      });
      expect(ada.crates, isNull);
    });

    test('named, they are all of them: an empty one clears every limit; not named, they are left as they are', () {
      final file = _read({
        'members': [
          {'email': 'ada@northwind.example', 'limits': <String, Object?>{}},
          {'email': 'lin@northwind.example', 'role': 'Members'},
        ],
      });
      expect(file.members![0].limits, isNotNull);
      expect(file.members![0].limits, isEmpty);
      expect(file.members![1].limits, isNull);
      expect(file.members![0].toJson(), {'email': 'ada@northwind.example', 'limits': <String, Object?>{}});
      expect(file.members![1].toJson().containsKey('limits'), isFalse);
    });

    test('a vault named both as extra access and as a limit is read: a role made by hand needs both', () {
      // (The approved design had such a file refused; an exported team that
      // has such a member must read back as itself.)
      final ada = _read({
        'members': [
          {
            'email': 'ada@northwind.example',
            'crates': {'Production': 'use'},
            'limits': {'Production': 'use'},
          },
        ],
      }).members!.single;
      expect(ada.crates, {'Production': levelSwitches(CrateLevel.use)});
      expect(ada.limits, {'Production': levelSwitches(CrateLevel.use)});
    });

    test('what is wrong with one is said with its place, and none is one of what may be written', () {
      List<String> wrong(Object? v) => _wrong({
            'members': [
              {
                'email': 'ada@northwind.example',
                'limits': {'A': v},
              },
            ],
          });
      const levels = 'none|connect|use|edit|manage|connect+agent|use+agent|edit+agent|manage+agent';
      expect(wrong('nothing'), ['notOneOf members[0].limits.A $levels']);
      expect(wrong('none+agent'), ['notOneOf members[0].limits.A $levels']);
      expect(wrong(''), ['notOneOf members[0].limits.A $levels']);
      expect(wrong(7), ['wrongKind members[0].limits.A limit']);
      expect(wrong(null), ['wrongKind members[0].limits.A limit']);
      expect(wrong(['reveal', 'sftp']), ['needsConnect members[0].limits.A']);
      final all = (CrateSwitches.all.toList()..sort()).join('|');
      expect(wrong(['connect', 'none']), ['notOneOf members[0].limits.A[1] $all']);
      // No access is no word for extra access: a vault left out of it is none.
      expect(
        _wrong({
          'members': [
            {
              'email': 'ada@northwind.example',
              'crates': {'A': 'none'},
            },
          ],
        }),
        ['notOneOf members[0].crates.A connect|use|edit|manage|connect+agent|use+agent|edit+agent|manage+agent'],
      );
      expect(
        _wrong({
          'members': [
            {'email': 'ada@northwind.example', 'limits': 'none'},
            {
              'email': 'lin@northwind.example',
              'limits': {'Production': 'none', ' production': 'connect'},
            },
            {
              'email': 'sam@northwind.example',
              'limits': {for (var i = 0; i <= kSetupMaxCrates; i++) 'Crate $i': 'none'},
            },
          ],
        }),
        [
          'wrongKind members[0].limits object',
          'duplicate members[1].limits. production production',
          'tooMany members[2].limits max 200',
        ],
      );
    });

    test('are written beside the extra access, No access as none, and read back as the same file', () {
      final file = _read({
        'members': [
          {
            'email': 'ada@northwind.example',
            'role': 'Members',
            'crates': {'Staging': 'use'},
            'limits': {
              'Production': 'none',
              'Staging': 'use',
              'Lab': ['connect', 'reveal'],
              'Edge': <String>[],
            },
            'until': '2027-01-31T17:00:00Z',
          },
        ],
      });
      final text = writeSetupFile(file);
      expect(text, '''
{
  "zestssh_setup": 2,
  "members": [
    {
      "email": "ada@northwind.example",
      "role": "Members",
      "crates": {
        "Staging": "use"
      },
      "limits": {
        "Production": "none",
        "Staging": "use",
        "Lab": [
          "connect",
          "reveal"
        ],
        "Edge": "none"
      },
      "until": "2027-01-31T17:00:00Z"
    }
  ]
}
''');
      final again = readSetupFile(text);
      expect(again.problems, isEmpty);
      expect(writeSetupFile(again.file!), text);
      expect(limitJson({}), kSetupNoAccess);
      expect(limitJson(levelSwitches(CrateLevel.edit)), 'edit');
      expect(limitJson({CrateSwitches.connect}), ['connect']);
    });

    test('a file is written as version 2 only where a member names limits, so one without them opens in older '
        'apps', () {
      expect(const SetupFile().version, kSetupFileFirstVersion);
      expect(
          writeSetupFile(const SetupFile(members: [SetupMember(email: 'ada@northwind.example', role: 'admin')])),
          contains('"zestssh_setup": 1,'));
      // An empty one names them: an app from before limits would not know
      // the field, and says the file is for a newer app.
      const cleared = SetupFile(members: [
        SetupMember(email: 'lin@northwind.example'),
        SetupMember(email: 'ada@northwind.example', limits: {}),
      ]);
      expect(cleared.version, kSetupFileLimitsVersion);
      expect(writeSetupFile(cleared), startsWith('{\n  "zestssh_setup": 2,'));
      // Whatever version a file says when it is read, it is written as what
      // it holds.
      final read = readSetupFile('{"zestssh_setup": 2, "crates": [{"name": "Lab"}]}').file!;
      expect(writeSetupFile(read), startsWith('{\n  "zestssh_setup": 1,'));
      // And an app of the first version refuses one of the second as newer.
      expect(kSetupFileLimitsVersion, greaterThan(kSetupFileFirstVersion));
    });
  });

  group('names told apart', () {
    test('by what they say, spaces at the ends and the case of letters aside', () {
      expect(setupNameKey(' Production '), 'production');
      expect(setupNameKey('PRODUCTION'), setupNameKey('production'));
      expect(setupNameKey('Production EU'), isNot(setupNameKey('ProductionEU')));
    });
  });

  group('every problem of a file at once', () {
    test('is found in one reading, part by part', () {
      final read = readSetupFile(_file({
        'orchard': '',
        'rules': {'reauth_days': 400},
        'crates': [
          {'name': 'A', 'hosts': [{'name': 'a', 'port': 0}]},
        ],
        'roles': [
          {'name': 'admin'},
        ],
        'members': [
          {'email': 'x'},
        ],
        'extra': 1,
      }));
      expect(read.ok, isFalse);
      expect(read.problems.map((p) => p.fault), [
        SetupFileFault.unknownField,
        SetupFileFault.empty,
        SetupFileFault.outOfRange,
        SetupFileFault.outOfRange,
        SetupFileFault.reservedRole,
        SetupFileFault.notAnAddress,
      ]);
      expect(read.problems.map((p) => p.path), [
        'extra',
        'orchard',
        'rules.reauth_days',
        'crates[0].hosts[0].port',
        'roles[0].name',
        'members[0].email',
      ]);
    });
  });
  group('a text with a quote in it', () {
    test('ends where it ends: the fields after it are told apart as ever', () {
      // One quote in a name (an odd number of them is what a reader that
      // took an escaped quote for the end of the text would trip over).
      final quote = '$_bs"';
      final text = '{"zestssh_setup": 1, "orchard": "the ${quote}north wing", '
          '"crates": [{"name": "5$quote rack"}, {"name": "A"}]}';
      expect(duplicateFields(text), isEmpty);
      final file = readSetupFile(text).file!;
      expect(file.orchard, 'the "north wing');
      expect(file.crates!.map((c) => c.name), ['5" rack', 'A']);
    });

    test('a field said twice after it is still found, at its own place', () {
      final quote = '$_bs"';
      final text = '{"zestssh_setup": 1, "orchard": "the ${quote}north wing", '
          '"crates": [{"name": "5$quote rack", "name": "B"}], "orchard": "x"}';
      expect(duplicateFields(text), ['crates[0].name', 'orchard']);
    });

    test('a backslash at the end of a text does not take the quote that ends it',
        () {
      final text = '{"zestssh_setup": 1, "orchard": "a$_bs$_bs", "orchard": "b"}';
      expect(duplicateFields(text), ['orchard']);
    });
  });

  group('a list of words with a wrong word in it', () {
    test('the words that are right still count for what else is wrong', () {
      // Two things are wrong here, and both are said in one reading: a word
      // that is none of them, and a watched Crate that allows something.
      expect(
        _wrong({
          'crates': [
            {'name': 'A', 'watched': true, 'allow': ['sftp', 'ports']},
          ],
        }),
        [
          'notOneOf crates[0].allow[1] agent|forward|sftp',
          'watchedAllows crates[0].allow',
        ],
      );
    });

    test('a watched Crate whose only word is wrong allows nothing, and is not said to',
        () {
      expect(
        _wrong({
          'crates': [
            {'name': 'A', 'watched': true, 'allow': ['ports']},
          ],
        }),
        ['notOneOf crates[0].allow[0] agent|forward|sftp'],
      );
    });
  });

  group('a time written in another zone', () {
    test('is the moment it names, whatever year it says there', () {
      // Ten hours behind UTC it is still 1969; the moment is in 1970.
      expect(parseSetupTime('1969-12-31T23:59:59-10:00'), 10 * 3600 - 1);
      expect(parseSetupTime('1969-12-31T23:59:59-00:01'), 59);
      // And one that is in 1970 where it is written, and before it in UTC.
      expect(parseSetupTime('1970-01-01T00:30:00+01:00'), isNull);
      expect(parseSetupTime('1969-12-31T23:59:59Z'), isNull);
      expect(parseSetupTime('0001-01-01T00:00:00Z'), isNull);
    });
  });

  group('how a host is written', () {
    test('its tags stand in one order, however they were put in', () {
      const a = SetupHost(name: 'web-1', tags: {'web', 'prod', 'eu'});
      const b = SetupHost(name: 'web-1', tags: {'eu', 'web', 'prod'});
      expect(a.toJson()['tags'], ['eu', 'prod', 'web']);
      expect(b.toJson()['tags'], a.toJson()['tags']);
    });
  });

  group('a name a file may carry as it is', () {
    test('has something in it, and no space at either end', () {
      expect(isSetupName('web-1', max: 10), isTrue);
      expect(isSetupName('web 1', max: 10), isTrue);
      expect(isSetupName('', max: 10), isFalse);
      expect(isSetupName('web-1 ', max: 10), isFalse);
      expect(isSetupName(' web-1', max: 10), isFalse);
      expect(isSetupName('web-1\t', max: 10), isFalse);
    });

    test('is as long as may be, and no longer', () {
      expect(isSetupName('a' * 10, max: 10), isTrue);
      expect(isSetupName('a' * 11, max: 10), isFalse);
      expect(isSetupName('a' * 9, max: 10), isTrue);
      // Counted in characters, not in what they take to store.
      expect(isSetupName(String.fromCharCode(0x1f34a) * 10, max: 10), isTrue);
      expect(isSetupName(String.fromCharCode(0x1f34a) * 11, max: 10), isFalse);
    });

    test('holds no character that does not show or turns the reading around',
        () {
      // A control, a soft hyphen, the Arabic letter mark, the Mongolian
      // vowel separator, a space of no width, the two direction marks, the
      // two line breaks, an embedding, the word joiner, a sign of no width,
      // an isolate, the last of the signs that are no longer used, a byte
      // order mark.
      for (final code in [
        0x00, 0x09, 0x1f, 0x7f, 0x85, 0x9f, 0xad, 0x61c, 0x180e, 0x200b, 0x200e, 0x200f, //
        0x2028, 0x2029, 0x202a, 0x202e, 0x2060, 0x2062, 0x2066, 0x2069, 0x206f, 0xfeff,
      ]) {
        expect(isSetupName('web${String.fromCharCode(code)}1', max: 10), isFalse,
            reason: 'U+${code.toRadixString(16)}');
        expect(
          _wrong({
            'crates': [
              {'name': 'Pro${String.fromCharCode(code)}d'},
            ],
          }),
          ['oddCharacters crates[0].name'],
          reason: 'U+${code.toRadixString(16)}',
        );
      }
    });

    test('may be spelled with the joiners some scripts and emoji need', () {
      for (final code in [0x200c, 0x200d]) {
        final name = 'a${String.fromCharCode(code)}b';
        expect(isSetupName(name, max: 10), isTrue, reason: 'U+${code.toRadixString(16)}');
        expect(
            _read({
              'crates': [
                {'name': name},
              ],
            }).crates!.single.name,
            name);
      }
      // And with what stands right next to the ones that are not let in.
      for (final code in [
        0x20, 0xa0, 0xac, 0xae, 0x61b, 0x61d, 0x180d, 0x180f, 0x200a, 0x2010, 0x2027, 0x202f, 0x205f, 0x2070, //
        0xfefe, 0xff00,
      ]) {
        expect(isSetupName('a${String.fromCharCode(code)}b', max: 10), isTrue,
            reason: 'U+${code.toRadixString(16)}');
      }
    });
  });
}
