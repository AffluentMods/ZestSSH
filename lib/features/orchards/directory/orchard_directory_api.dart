import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/pinned_http_client.dart';

/// What a directory group maps to: an Orchard role id, 'admin', or null
/// for none (3.0).
class DirectoryGroup {
  const DirectoryGroup({required this.id, required this.name, this.role, this.members = 0, this.autoRole = false});

  final String id;
  final String name;
  final String? role;
  final int members;

  /// Its role was made for it by an owner's device (directory groups become
  /// roles, 3.3.0): the role's name follows the group's.
  final bool autoRole;

  static DirectoryGroup? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    if (id is! String || name is! String) return null;
    final members = raw['members'];
    return DirectoryGroup(
      id: id,
      name: name,
      role: raw['role'] is String ? raw['role'] as String : null,
      members: members is int ? members : 0,
      autoRole: raw['auto_role'] == true,
    );
  }
}

/// The kinds of change the directory asks for. Removals and lower roles
/// already took effect on the server (the member is held back until the
/// record catches up); adding someone and raising a role wait for a person.
enum DirectoryChangeKind {
  add,
  raise,
  lower,
  remove;

  static DirectoryChangeKind? parse(Object? v) => switch (v) {
        'add' => add,
        'raise' => raise,
        'lower' => lower,
        'remove' => remove,
        _ => null,
      };
}

/// A change the company's directory asked for, waiting for an owner's or
/// admin's device to act on it (or set it aside).
class DirectoryChange {
  const DirectoryChange({required this.id, required this.kind, required this.email, this.uid, this.role});

  final int id;
  final DirectoryChangeKind kind;

  /// The address the directory named.
  final String email;

  /// The member it is about; null for someone to add.
  final String? uid;

  /// The role the directory's groups give them now; null for none.
  final String? role;

  static DirectoryChange? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final kind = DirectoryChangeKind.parse(raw['kind']);
    final email = raw['email'];
    if (id is! int || kind == null || email is! String) return null;
    return DirectoryChange(
      id: id,
      kind: kind,
      email: email,
      uid: raw['uid'] is String ? raw['uid'] as String : null,
      role: raw['role'] is String ? raw['role'] as String : null,
    );
  }
}

/// An Orchard's directory sync as owners and admins see it.
class OrchardDirectory {
  const OrchardDirectory({
    this.enabled = false,
    this.scimUrl,
    this.lastContact,
    this.lowers = false,
    this.autoRoles = false,
    this.groups = const [],
    this.pending = const [],
    this.held = const [],
  });

  final bool enabled;

  /// Where the company's directory sends its changes (SCIM 2.0 base URL).
  final String? scimUrl;

  /// When the directory last reached ZestSSH Cloud; null for never.
  final DateTime? lastContact;

  /// Whether the directory may ask to lower a role too. Off (where the
  /// team said nothing), it adds and raises only: a role an owner gave by
  /// hand stays.
  final bool lowers;

  /// Whether an owner's device makes a role for each group that gives none
  /// (3.3.0: groups made in the directory
  /// update the roles automatically). Off unless an owner turns it on.
  final bool autoRoles;
  final List<DirectoryGroup> groups;
  final List<DirectoryChange> pending;

  /// Members the directory took away, held back until the record catches up.
  final List<({String uid, String email})> held;

  static OrchardDirectory fromJson(Map<String, dynamic> raw) {
    List<T> list<T>(Object? v, T? Function(Object?) one) => [
          if (v is List)
            for (final x in v) ?one(x),
        ];
    return OrchardDirectory(
      enabled: raw['enabled'] == true,
      scimUrl: raw['scim_url'] is String ? raw['scim_url'] as String : null,
      lastContact: raw['last_contact'] is String ? DateTime.tryParse(raw['last_contact'] as String) : null,
      lowers: raw['lowers'] == true,
      autoRoles: raw['auto_roles'] == true,
      groups: list(raw['groups'], DirectoryGroup.fromJson),
      pending: list(raw['pending'], DirectoryChange.fromJson),
      held: list(raw['held'], (x) {
        if (x is! Map || x['uid'] is! String) return null;
        return (uid: x['uid'] as String, email: x['email'] is String ? x['email'] as String : '');
      }),
    );
  }
}

/// Where someone in a directory group stands in the team.
enum DirectoryPersonState {
  member,
  waiting,
  invited,
  outside;

  static DirectoryPersonState parse(Object? v) => switch (v) {
        'member' => member,
        'waiting' => waiting,
        'invited' => invited,
        _ => outside,
      };
}

/// Someone in a directory group: their address as the directory sent it,
/// whether the directory has them on, where they stand, and their role
/// where they are a member.
typedef DirectoryPerson = ({String email, bool active, DirectoryPersonState state, String? role});

/// A directory token, shown this once, and where the directory sends to.
typedef DirectoryToken = ({String token, String scimUrl});

/// ZestSSH Cloud's directory sync routes for an Orchard: what
/// the directory sent (owners and admins), turning it on and off, a new
/// token, which role each group gives (owners), and setting a change aside
/// once it is dealt with (owners and admins). Errors are
/// [OrchardServerException]s: 'forbidden', 'domain-required',
/// 'directory-on', 'directory-off', 'invalid-request',
/// 'recent-sign-in-required', 'not-found'.
class OrchardDirectoryApi {
  OrchardDirectoryApi({http.Client? client, String? baseUrl, required this.bearer})
      : _client = client ?? PinnedHttpClient.client,
        _base = baseUrl ?? OrchardsApi.defaultBase;

  final http.Client _client;
  final String _base;

  /// The account's bearer: the Firebase ID token on phones, the session
  /// token on desktop. Null when signed out.
  final Future<String?> Function() bearer;

  static const _timeout = Duration(seconds: 30);

  Uri _uri(String orchardId, [String? tail]) =>
      Uri.parse('$_base/orchards/$orchardId/directory${tail == null ? '' : '/$tail'}');

  Future<Map<String, dynamic>> _send(Future<http.Response> Function(Map<String, String> headers) send,
      {bool json = false}) async {
    final token = await bearer();
    if (token == null) throw const OrchardServerException(401, 'signed-out');
    final response = await send({
      'Authorization': 'Bearer $token',
      ...DeviceSessionHeader.headers,
      if (json) 'Content-Type': 'application/json',
    }).timeout(_timeout);
    reportIfSessionRevoked(response);
    Map<String, dynamic> body;
    try {
      final decoded = jsonDecode(response.body);
      body = decoded is Map<String, dynamic> ? decoded : const {};
    } catch (_) {
      body = const {};
    }
    if (response.statusCode == 200 || response.statusCode == 201) return body;
    throw OrchardServerException(response.statusCode, body['code'] is String ? body['code'] as String : null);
  }

  DirectoryToken _token(Map<String, dynamic> body) {
    final token = body['token'];
    final url = body['scim_url'];
    if (token is! String || url is! String) throw const FormatException('Not a directory token');
    return (token: token, scimUrl: url);
  }

  /// The Orchard's directory sync.
  Future<OrchardDirectory> get(String orchardId) async =>
      OrchardDirectory.fromJson(await _send((h) => _client.get(_uri(orchardId), headers: h)));

  /// Turns it on: the token, shown this once.
  Future<DirectoryToken> enable(String orchardId) async =>
      _token(await _send((h) => _client.post(_uri(orchardId), headers: h)));

  /// A new token, shown this once; the old one stops working.
  Future<DirectoryToken> newToken(String orchardId) async =>
      _token(await _send((h) => _client.post(_uri(orchardId, 'token'), headers: h)));

  /// Turns it off: what the directory sent goes, and every hold it put on
  /// someone is lifted.
  Future<void> disable(String orchardId) async {
    await _send((h) => _client.delete(_uri(orchardId), headers: h));
  }

  /// Which role [groupId]'s members get: a role id, 'admin', or null.
  /// [auto]: a role this device made for the group, whose name follows it.
  Future<DirectoryGroup> mapGroup(String orchardId, String groupId, String? role, {bool auto = false}) async {
    final body = await _send(
      (h) => _client.put(_uri(orchardId, 'groups/${Uri.encodeComponent(groupId)}'),
          headers: h, body: jsonEncode({'role': role, if (auto) 'auto': true})),
      json: true,
    );
    return DirectoryGroup.fromJson(body) ?? (throw const FormatException('Not a group'));
  }

  /// Who is in the group [groupId] (owners and admins).
  Future<List<DirectoryPerson>> groupPeople(String orchardId, String groupId) async {
    final body = await _send(
        (h) => _client.get(_uri(orchardId, 'groups/${Uri.encodeComponent(groupId)}/people'), headers: h));
    final list = body['people'];
    return [
      if (list is List)
        for (final p in list)
          if (p is Map && p['email'] is String)
            (
              email: p['email'] as String,
              active: p['active'] != false,
              state: DirectoryPersonState.parse(p['state']),
              role: p['role'] is String ? p['role'] as String : null,
            ),
    ];
  }

  /// Whether the directory may ask to lower roles too (owners, with a
  /// recent sign-in). Turned off, what waits to lower someone goes.
  Future<void> setLowers(String orchardId, bool lowers) async {
    await _send(
      (h) => _client.put(_uri(orchardId, 'settings'), headers: h, body: jsonEncode({'lowers': lowers})),
      json: true,
    );
  }

  /// Whether an owner's device makes a role for each directory group
  /// (owners, with a recent sign-in).
  Future<void> setAutoRoles(String orchardId, bool on) async {
    await _send(
      (h) => _client.put(_uri(orchardId, 'settings'), headers: h, body: jsonEncode({'auto_roles': on})),
      json: true,
    );
  }

  /// Sets a change aside, once this device dealt with it (or chose not to).
  /// A change already gone (404) counts as set aside.
  Future<void> dismiss(String orchardId, int changeId) async {
    try {
      await _send((h) => _client.delete(_uri(orchardId, 'changes/$changeId'), headers: h));
    } on OrchardServerException catch (e) {
      if (!e.notFound) rethrow;
    }
  }
}
