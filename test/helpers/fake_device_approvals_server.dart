import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/services/account/device_approvals.dart';

/// A stand-in for ZestSSH Cloud's new-device approvals (3.0)
/// that keeps the same stages and JSON as ZestSSH Cloud's
/// routes/device_approvals.js. Each device is named by its session header.

String approvalHex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// One request as the server keeps it.
class FakeApprovalRow {
  FakeApprovalRow(this.id, this.creator, this.commitment, this.name);

  final String id;
  final String creator;
  final Uint8List commitment;
  final String name;
  String stage = 'created';
  String? approver;
  Uint8List? approverKey, approverNonce, newKey, newNonce, sealed;
}

/// The server's stages, per device (the session header names the device).
class FakeApprovalServer {
  final rows = <String, FakeApprovalRow>{};
  var _next = 0;

  /// What the server shows the approving device of the new device's
  /// reveal: null forwards it as it is; set, it swaps in other bytes.
  (Uint8List, Uint8List)? swapReveal;

  /// Set, the commitment the approving device reads once it has answered
  /// (a server that swaps the reveal and the commitment together).
  Uint8List? swapCommitment;

  /// Set, answering is refused with this code (as the server's
  /// 'recent-sign-in-required' when the approver's sign-in is not recent).
  String? refuseRespond;

  /// Every request a device cancelled, by id.
  final cancelled = <String>[];

  /// While above zero, reading one request fails (with [failReadStatus])
  /// and counts down: a server at fault for a moment.
  int failReads = 0;

  /// The status a read that fails is answered with.
  int failReadStatus = 500;

  /// While true nothing answers: every request fails as a connection that
  /// could not be made.
  bool offline = false;

  late final client = MockClient((req) async {
    if (offline) throw const SocketException('Connection refused');
    final device = req.headers['x-zestssh-session']!;
    final path = req.url.path.replaceFirst('/v1/account/device-approvals', '');
    final body = req.body.isEmpty ? const <String, dynamic>{} : jsonDecode(req.body) as Map<String, dynamic>;
    http.Response json(Object o, [int status = 200]) => http.Response(jsonEncode(o), status);
    http.Response error(int status, String code) => json({'error': code, 'code': code}, status);
    Map<String, Object?> summary(FakeApprovalRow r, String role) => {
          'id': r.id,
          'role': role,
          'stage': r.stage,
          'name': r.name,
          'expires_in': 600,
        };
    String roleOf(FakeApprovalRow r) => r.creator == device ? 'new' : (r.approver == device ? 'approver' : 'open');

    if (path.isEmpty && req.method == 'POST') {
      final id = 'req-${_next++}';
      rows.removeWhere((_, r) => r.creator == device);
      rows[id] = FakeApprovalRow(id, device, fromB64url(body['commitment'])!, body['name'] as String);
      return json(summary(rows[id]!, 'new'), 201);
    }
    if (path.isEmpty && req.method == 'GET') {
      return json({
        'requests': [
          for (final r in rows.values)
            if (r.creator == device || r.approver == device || (r.approver == null)) summary(r, roleOf(r)),
        ],
      });
    }
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    final row = rows[parts.first];
    if (row == null) return error(404, 'not-found');
    final role = roleOf(row);
    if (parts.length == 1 && req.method == 'GET') {
      if (failReads > 0) {
        failReads--;
        return error(failReadStatus, 'server-error');
      }
      final out = summary(row, role);
      if (role == 'new') {
        if (row.approverKey != null) {
          out['approver_public_key'] = b64url(row.approverKey!);
          out['approver_nonce'] = b64url(row.approverNonce!);
        }
      } else {
        final swapped = swapCommitment;
        out['commitment'] = b64url(role == 'approver' && swapped != null ? swapped : row.commitment);
        if (role == 'approver' && row.newKey != null) {
          final swap = swapReveal;
          out['new_public_key'] = b64url(swap?.$1 ?? row.newKey!);
          out['new_nonce'] = b64url(swap?.$2 ?? row.newNonce!);
        }
      }
      return json(out);
    }
    if (parts.length == 1 && req.method == 'DELETE') {
      // Either side, or any of the account's devices while nobody answered.
      if (role == 'open' && row.stage != 'created') return error(404, 'not-found');
      rows.remove(row.id);
      cancelled.add(row.id);
      return json({'cancelled': true});
    }
    switch (parts[1]) {
      case 'respond':
        if (role == 'new') return error(403, 'same-device');
        if (row.stage != 'created') return error(409, 'wrong-stage');
        final refusal = refuseRespond;
        if (refusal != null) return error(403, refusal);
        row
          ..stage = 'responded'
          ..approver = device
          ..approverKey = fromB64url(body['public_key'])
          ..approverNonce = fromB64url(body['nonce']);
        return json({'id': row.id, 'stage': 'responded'});
      case 'reveal':
        if (role != 'new') return error(403, 'wrong-device');
        if (row.stage != 'responded') return error(409, 'wrong-stage');
        final key = fromB64url(body['public_key'])!;
        final nonce = fromB64url(body['nonce'])!;
        if (approvalHex(approvalCommitment(key, nonce)) != approvalHex(row.commitment)) {
          rows.remove(row.id);
          return error(409, 'commitment-mismatch');
        }
        row
          ..stage = 'revealed'
          ..newKey = key
          ..newNonce = nonce;
        return json({'id': row.id, 'stage': 'revealed'});
      case 'seal':
        if (role != 'approver') return error(403, 'wrong-device');
        if (row.stage != 'revealed') return error(409, 'wrong-stage');
        row
          ..stage = 'sealed'
          ..sealed = fromB64url(body['sealed']);
        return json({'id': row.id, 'stage': 'sealed'});
      case 'receive':
        if (role != 'new') return error(403, 'wrong-device');
        if (row.stage != 'sealed') return error(409, 'wrong-stage');
        rows.remove(row.id);
        return json({'sealed': b64url(row.sealed!)});
    }
    return error(404, 'not-found');
  });

  DeviceApprovalsApi device(String session) => DeviceApprovalsApi(
        client: client,
        baseUrl: 'https://cloud.test/v1',
        bearer: () async => 'token',
        sessionHeaders: () => {'X-ZestSSH-Session': session},
      );
}
