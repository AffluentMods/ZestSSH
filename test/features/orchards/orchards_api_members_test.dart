import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';

/// The member list as the app reads it from ZestSSH Cloud (to-do 59): each
/// member's name and picture as their own account shows them. A picture is
/// taken only at an https address; anything else is none, and so are a blank
/// name and an older server that sends neither.
void main() {
  OrchardsApi api(List<Map<String, Object?>> members) => OrchardsApi(
        client: MockClient((request) async => http.Response(jsonEncode({'members': members}), 200,
            headers: {'content-type': 'application/json'})),
        baseUrl: 'https://api.test/v1',
        bearer: () async => 'token',
      );

  Map<String, Object?> member(String uid, {Object? name, Object? picture}) => {
        'uid': uid,
        'role': 'member',
        'status': 'active',
        'email': '$uid@example.com',
        'name': ?name,
        'picture': ?picture,
      };

  test("a member's name and picture", () async {
    final list = await api([
      member('alice', name: '  Alice Example ', picture: 'https://lh3.googleusercontent.com/a/alice'),
    ]).members('o-1');
    final alice = list.members.single;
    expect((alice.name, alice.picture, alice.email),
        ('Alice Example', 'https://lh3.googleusercontent.com/a/alice', 'alice@example.com'));
  });

  test('none for a blank name, a picture not at an https address, or an older server that sends neither',
      () async {
    final list = await api([
      member('a', name: '   ', picture: 'http://images.example.com/a.png'),
      member('b', name: 42, picture: 'javascript:alert(1)'),
      member('c', picture: 'https://${'x' * 2050}.example.com/c.png'),
      member('d', picture: 'https:///no-host.png'),
      member('f', picture: 'https://images.example.com/f.png'),
      member('e'),
    ]).members('o-1');
    for (final m in list.members) {
      expect((m.name, m.picture), (null, null), reason: m.uid);
    }
  });
}
