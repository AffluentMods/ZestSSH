import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/sharing/share_invitation.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/pinned_http_client.dart';

/// An invitation to a shared session as ZestSSH Cloud lists it: where it is
/// from and the sealed invitation itself. Everything said here is checked
/// against what the person sharing signed ([shareInvitationProblem]) before
/// any of it is shown or acted on.
class ShareInviteListing {
  const ShareInviteListing({
    required this.shareId,
    required this.orchardId,
    required this.crateId,
    required this.mode,
    required this.fromUid,
    required this.sealed,
    required this.expiresIn,
  });

  final String shareId;
  final String orchardId;
  final String crateId;
  final ShareMode mode;

  /// The account that shares.
  final String fromUid;

  /// The invitation, sealed to this account's key.
  final Uint8List sealed;

  /// How long the share can still last, at most.
  final Duration expiresIn;

  /// One entry of the server's list; null when it is not one.
  static ShareInviteListing? fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final shareId = raw['share_id'];
    final orchardId = raw['orchard_id'];
    final crateId = raw['crate_id'];
    final from = raw['from'];
    final sealed = raw['sealed'];
    final expiresIn = raw['expires_in'];
    final mode = switch (raw['mode']) {
      'live' => ShareMode.live,
      'tmux' => ShareMode.tmux,
      _ => null,
    };
    if (shareId is! String ||
        orchardId is! String ||
        crateId is! String ||
        from is! String ||
        sealed is! String ||
        expiresIn is! int ||
        mode == null) {
      return null;
    }
    final Uint8List bytes;
    try {
      bytes = base64Decode(sealed);
    } on FormatException {
      return null;
    }
    if (bytes.isEmpty || bytes.length > kShareSealedMax) return null;
    return ShareInviteListing(
      shareId: shareId,
      orchardId: orchardId,
      crateId: crateId,
      mode: mode,
      fromUid: from,
      sealed: bytes,
      expiresIn: Duration(seconds: expiresIn < 0 ? 0 : expiresIn),
    );
  }
}

/// Someone invited cannot open the Crate (any more): [uids] says who.
class ShareNoAccess extends OrchardServerException {
  const ShareNoAccess(this.uids) : super(409, 'no-access');

  final List<String> uids;

  @override
  String get typeName => 'ShareNoAccess';
}

/// ZestSSH Cloud's routes for sharing a session (ZestSSH Cloud's
/// routes/shares.js). The server lets the right people in and passes each
/// their sealed invitation; it never sees which host or session is shared.
/// Errors are [OrchardServerException]s: 'not-found' (no such share, or not
/// yours), 'invalid-request', 'id-taken', 'too-many-shares' (three at
/// once), 'share-full' (eight people), 'rate-limited', 'rules-unmet',
/// 'directory-removed', 'signed-out', or [ShareNoAccess].
class ShareApi {
  ShareApi({http.Client? client, String? baseUrl, required this.bearer})
      : _client = client ?? PinnedHttpClient.client,
        _base = baseUrl ?? OrchardsApi.defaultBase;

  final http.Client _client;
  final String _base;

  /// The account's bearer: the Firebase ID token on phones, the session
  /// token on desktop. Null when signed out.
  final Future<String?> Function() bearer;

  static const _timeout = Duration(seconds: 30);

  Uri _uri([String tail = '']) => Uri.parse('$_base/shares$tail');

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
    final code = body['code'] is String ? body['code'] as String : null;
    if (response.statusCode == 409 && code == 'no-access') {
      final uids = body['uids'];
      throw ShareNoAccess([
        if (uids is List)
          for (final u in uids)
            if (u is String) u,
      ]);
    }
    final unmet = body['unmet'];
    throw OrchardServerException(response.statusCode, code, unmet: [
      if (unmet is List)
        for (final u in unmet)
          if (u is String) u,
    ]);
  }

  static List<Map<String, String>> _invites(Map<String, Uint8List> sealed) => [
        for (final e in sealed.entries) {'uid': e.key, 'sealed': base64Encode(e.value)},
      ];

  /// Starts the share [id] in [crateId], with one sealed invitation for
  /// each account in [invites]. Sending it again after a lost answer is
  /// answered as a success.
  Future<void> create({
    required String id,
    required String crateId,
    required ShareMode mode,
    required Map<String, Uint8List> invites,
  }) =>
      _send(
        (h) => _client.post(_uri(),
            headers: h,
            body: jsonEncode({
              'id': id,
              'crate_id': crateId,
              'mode': mode.name,
              'invites': _invites(invites),
            })),
        json: true,
      );

  /// Invites more people to the share [id] (the person sharing). Someone
  /// already invited gets the new invitation in place of the old one.
  Future<void> invite(String id, Map<String, Uint8List> invites) => _send(
        (h) => _client.post(_uri('/$id/invites'), headers: h, body: jsonEncode({'invites': _invites(invites)})),
        json: true,
      );

  /// The invitations waiting for this account. Entries this version cannot
  /// read are left out.
  Future<List<ShareInviteListing>> invitations() async {
    final body = await _send((h) => _client.get(_uri('/invites'), headers: h));
    final list = body['invites'];
    if (list is! List) throw const FormatException('Not a list of invitations');
    return [for (final i in list) ?ShareInviteListing.fromJson(i)];
  }

  /// Takes [uid]'s invitation to the share [id] back (the person sharing),
  /// or declines this account's own.
  Future<void> removeInvite(String id, String uid) =>
      _send((h) => _client.delete(_uri('/$id/invites/${Uri.encodeComponent(uid)}'), headers: h));

  /// Stops sharing [id]: everyone connected is dropped and nothing of the
  /// share is kept.
  Future<void> end(String id) => _send((h) => _client.delete(_uri('/$id'), headers: h));
}
