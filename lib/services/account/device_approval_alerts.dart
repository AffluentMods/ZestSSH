import 'dart:async';

import 'package:zestssh/services/account/device_approvals.dart';
import 'package:zestssh/utils/logger.dart';

/// Word from the live line that a new-device approval of this account moved
/// on (3.0; ZestSSH Cloud's lib/stream.js sends
/// `{type: 'device-approval', id}`). The Orchards sync adds to it; the app
/// shell listens ([DeviceApprovalAlerts]).
final StreamController<String> deviceApprovalNudges = StreamController<String>.broadcast();

/// Tells the person when a new device of theirs asks for the sync key and
/// this device could hand it over, with a way straight to the approval. The
/// live line is open while the account is in an Orchard, so teams hear at
/// once; anyone can always approve from Account, Devices.
///
/// Each request is told about once. Nothing is told for a request someone
/// already answered, for this device's own request, or where this device
/// holds no key it could send.
class DeviceApprovalAlerts {
  DeviceApprovalAlerts({required this.api, required this.canApprove, required this.tell});

  final DeviceApprovalsApi Function() api;

  /// Whether this device holds the sync key on ZestSSH Cloud.
  final Future<bool> Function() canApprove;

  /// Shows the request to the person.
  final void Function(DeviceApprovalRequest request) tell;

  final _told = <String>{};

  Future<void> heard(String id) async {
    if (_told.contains(id)) return;
    try {
      if (!await canApprove()) return;
      final request = await api().get(id);
      if (request.role != 'open' || request.stage != 'created') return;
      if (!_told.add(id)) return;
      tell(request);
    } catch (e) {
      // Gone already, or no connection: the Devices row still has it.
      AppLogger.info('Device approval: word from the live line not followed ($e)');
    }
  }
}
