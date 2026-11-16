import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';

/// What the app reads of the server's answers about an Orchard's rules (3.0
/// release): an Orchard it is held back from (which rules, for the address
/// rule the domains allowed, and the rules its devices keep to meanwhile),
/// the refusals that name the rules, and the rules an invitation or an
/// acceptance falls short of.

void main() {
  http.Response json(int status, Object body) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

  OrchardsApi api(Future<http.Response> Function(http.Request request) answer) =>
      OrchardsApi(client: MockClient(answer), baseUrl: 'https://api.test/v1', bearer: () async => 'token');

  test('the list: an Orchard held back by its rules says which, with its role and the domains allowed', () async {
    final orchards = await api((request) async => json(200, {
          'orchards': [
            {
              'id': 'o-active',
              'status': 'active',
              'name_enc': base64Encode([1, 2, 3]),
              'key_generation': 1,
              'record_seq': 4,
              'role': 'owner',
              'can': <String>[],
              'members_tag': 'tag',
              'invites_waiting': 0,
              'rotation_due': false,
              'keys': <Object>[],
              'crates': <Object>[],
            },
            {
              'id': 'o-held',
              'status': 'rules',
              'role': 'member-role',
              'unmet': ['two_step', 'email_domain', 'something_new'],
              'email_domains': ['corp.example', 'example.com'],
              'device_rules': {
                'require_app_lock': true,
                'max_lock_minutes': 15,
                'no_export': true,
                'offline_hours': 72,
              },
            },
            {'id': 'o-suspended', 'status': 'suspended'},
          ],
        })).orchards();

    expect(orchards.map((o) => (o.id, o.status, o.active)), [
      ('o-active', 'active', true),
      ('o-held', 'rules', false),
      ('o-suspended', 'suspended', false),
    ]);
    final held = orchards[1];
    expect(held.role, 'member-role');
    expect(held.rulesUnmet, ['two_step', 'email_domain', 'something_new'], reason: 'kept in order, unknown ones too');
    expect(held.ruleDomains, ['corp.example', 'example.com']);
    final device = held.heldDeviceRules!;
    expect((device.requireAppLock, device.maxLockMinutes, device.noExport, device.offlineHours), (true, 15, true, 72),
        reason: 'the rules its devices keep to meanwhile');
    expect(held.keys, isEmpty);
    expect(held.crates, isEmpty);
    expect(orchards[0].rulesUnmet, isEmpty);
    expect(orchards[0].heldDeviceRules, isNull);
  });

  test('the list: a server that does not name the device rules, or names them wrongly, gives none', () async {
    final orchards = await api((request) async => json(200, {
          'orchards': [
            {'id': 'o-older', 'status': 'rules', 'role': 'owner', 'unmet': ['two_step']},
            {'id': 'o-odd', 'status': 'rules', 'role': 'owner', 'unmet': ['two_step'], 'device_rules': 'no_export'},
            {
              'id': 'o-typed',
              'status': 'rules',
              'role': 'owner',
              'unmet': ['two_step'],
              'device_rules': {'require_app_lock': 'yes', 'max_lock_minutes': '15', 'no_export': 1, 'offline_hours': 2.5},
            },
          ],
        })).orchards();
    expect(orchards[0].heldDeviceRules, isNull);
    expect(orchards[1].heldDeviceRules, isNull);
    expect(orchards[2].heldDeviceRules?.isNone, isTrue, reason: 'anything of the wrong kind reads as off');
  });

  test('refusals that name the rules', () async {
    // Reading the record: held back. Adding to it: rules the sender does not meet.
    final server = api((request) async => request.method == 'GET'
        ? json(403, {'code': 'rules-unmet', 'unmet': ['reauth']})
        : json(409, {'code': 'rules-unmet-by-you', 'unmet': ['two_step']}));
    await expectLater(
      server.record('o', after: 0),
      throwsA(isA<OrchardServerException>()
          .having((e) => e.rulesUnmet, 'rules-unmet', isTrue)
          .having((e) => e.unmet, 'unmet', ['reauth'])),
    );
    await expectLater(
      server.appendRecord('o', const []),
      throwsA(isA<OrchardServerException>()
          .having((e) => e.code, 'code', 'rules-unmet-by-you')
          .having((e) => e.rulesUnmet, 'rules-unmet', isFalse)
          .having((e) => e.unmet, 'unmet', ['two_step'])),
    );
  });

  test('invitations: what this account does not meet yet, and what someone accepted without', () async {
    final server = api((request) async => request.url.path == '/v1/invites'
        ? json(200, {
            'invites': [
              {
                'id': 'i-1',
                'orchard_id': 'o',
                'role': 'member-role',
                'crates': 1,
                'expires_at': '2026-10-08T00:00:00.000Z',
                'accepted': false,
                'rules_unmet': ['two_step'],
              },
            ],
          })
        : json(200, {
            'invites': [
              {
                'id': 'i-2',
                'email': 'dave@example.com',
                'role': 'member-role',
                'grants': <String, Object>{},
                'expires_at': '2026-10-08T00:00:00.000Z',
                'expired': false,
                'accepted': {'uid': 'dave', 'keys': null, 'rules_unmet': ['two_step', 'reauth']},
              },
              {
                'id': 'i-3',
                'email': 'erin@example.com',
                'role': 'member-role',
                'grants': <String, Object>{},
                'expires_at': '2026-10-08T00:00:00.000Z',
                'expired': false,
                'accepted': null,
              },
            ],
          }));
    expect((await server.myInvites()).single.rulesUnmet, ['two_step']);
    final invites = await server.invites('o');
    expect(invites[0].acceptedRulesUnmet, ['two_step', 'reauth']);
    expect(invites[1].accepted, isFalse);
    expect(invites[1].acceptedRulesUnmet, isEmpty);
  });

  // The company's directory holds this account back from one Orchard,
  // which the server lists as 'directory-removed': the app did not know it
  // and threw, so every Orchard of the account stopped refreshing. Any
  // standing this app does not know is an Orchard it cannot open for now.
  test('the list: an Orchard the directory holds back, or of a standing this app does not know, never fails the others',
      () async {
    final orchards = await api((request) async => json(200, {
          'orchards': [
            {'id': 'o-held-by-directory', 'status': 'directory-removed'},
            {
              'id': 'o-active',
              'status': 'active',
              'name_enc': base64Encode([1, 2, 3]),
              'key_generation': 1,
              'record_seq': 4,
              'role': 'owner',
              'can': <String>[],
              'members_tag': 'tag',
              'invites_waiting': 0,
              'rotation_due': false,
              'keys': <Object>[],
              'crates': <Object>[],
            },
            {'id': 'o-later', 'status': 'something-new'},
            {'id': 'o-ended', 'status': 'ended'},
          ],
        })).orchards();
    expect(orchards.map((o) => (o.id, o.status, o.active)), [
      ('o-held-by-directory', 'directory-removed', false),
      ('o-active', 'active', true),
      ('o-later', 'something-new', false),
      ('o-ended', 'ended', false),
    ]);
    expect(orchards[0].keys, isEmpty);
    expect(orchards[0].crates, isEmpty);
    // Still refused: an entry that is no Orchard at all.
    await expectLater(
        api((request) async => json(200, {
              'orchards': [
                {'status': 'suspended'},
              ],
            })).orchards(),
        throwsFormatException);
  });
}
