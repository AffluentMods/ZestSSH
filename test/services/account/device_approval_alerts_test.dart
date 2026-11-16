import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/account/device_approval_alerts.dart';
import 'package:zestssh/services/account/device_approvals.dart';

import '../../helpers/fake_device_approvals_server.dart';

/// The alert when a new device of the account asks for the sync key (3.0),
/// from the live line's word: told once per request, and
/// only when this device could hand the key over and nobody answered yet.
void main() {
  late FakeApprovalServer server;
  late List<DeviceApprovalRequest> told;
  late bool holdsKey;
  late int reads;

  setUp(() {
    server = FakeApprovalServer();
    told = [];
    holdsKey = true;
    reads = 0;
  });

  DeviceApprovalAlerts alerts() => DeviceApprovalAlerts(
        api: () {
          reads++;
          return server.device('desktop');
        },
        canApprove: () async => holdsKey,
        tell: told.add,
      );

  test('a new device asks: told once, with its name', () async {
    final ask = await ApprovalAsk.start(server.device('phone'), name: 'Pixel');
    final a = alerts();
    await Future.wait([a.heard(ask.id), a.heard(ask.id)]);
    await a.heard(ask.id);
    expect(told.map((r) => (r.id, r.name)), [(ask.id, 'Pixel')]);
    expect(reads, 2, reason: 'a request already told about is not read again');
  });

  test('already answered: nothing told', () async {
    final ask = await ApprovalAsk.start(server.device('phone'), name: 'Pixel');
    await ApprovalGive.answer(server.device('laptop'), ask.id);
    await alerts().heard(ask.id);
    expect(told, isEmpty);
  });

  test('no key on this device, or its own request: nothing told', () async {
    final ask = await ApprovalAsk.start(server.device('phone'), name: 'Pixel');
    holdsKey = false;
    await alerts().heard(ask.id);
    expect(told, isEmpty);

    holdsKey = true;
    final own = await ApprovalAsk.start(server.device('desktop'), name: 'Windows');
    await alerts().heard(own.id);
    expect(told, isEmpty);
  });

  test('a request already gone: nothing told, nothing thrown', () async {
    await alerts().heard('req-gone');
    expect(told, isEmpty);
  });
}
