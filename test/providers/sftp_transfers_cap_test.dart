import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/providers/sftp_transfers_provider.dart';
import 'package:zestssh/ui/screens/sftp/widgets/transfer_queue_panel.dart';

/// The transfer list keeps a bounded number of finished rows (found in a
/// review): every file ever sent stayed until the person cleared the
/// list, and the whole list is copied at each publish.
void main() {
  TransferItem item(String id, {String? op, TransferStatus status = TransferStatus.completed}) {
    final t = TransferItem(
      id: id,
      localPath: 'C:/work/$id',
      remotePath: '/srv/$id',
      fileName: id,
      direction: TransferDirection.upload,
      totalBytes: 10,
      operationId: op,
    );
    t.status = status;
    return t;
  }

  test('finished rows past the cap go, oldest first, whole operations at a time; failed ones stay', () {
    final n = SftpTransfersNotifier();
    addTearDown(n.dispose);
    const cap = SftpTransfersNotifier.maxFinishedRows;
    // An old finished drop of 600 files, one of them failed.
    for (var i = 0; i < 600; i++) {
      n.add(item('old-$i', op: 'old', status: i == 7 ? TransferStatus.failed : TransferStatus.completed));
    }
    // A drop still running: 500 finished and one not.
    for (var i = 0; i < 500; i++) {
      n.add(item('run-$i', op: 'run'));
    }
    n.add(item('run-last', op: 'run', status: TransferStatus.active));
    n.touchNow();
    expect(n.findById('old-0'), isNull, reason: 'the old drop went whole');
    expect(n.findById('old-599'), isNull);
    expect(n.findById('old-7'), isNotNull, reason: 'a failed row stays for Retry');
    expect(n.findById('run-0'), isNotNull, reason: 'a running drop keeps every row');
    expect(n.findById('run-last'), isNotNull);

    // Single files past the cap.
    for (var i = 0; i < cap + 50; i++) {
      n.add(item('one-$i'));
    }
    n.touchNow();
    expect(n.findById('one-0'), isNull);
    expect(n.findById('one-${cap + 49}'), isNotNull);
    expect(n.findById('run-0'), isNotNull);
  });

  test('under the cap nothing goes', () {
    final n = SftpTransfersNotifier();
    addTearDown(n.dispose);
    for (var i = 0; i < 300; i++) {
      n.add(item('f-$i'));
    }
    n.touchNow();
    expect(n.findById('f-0'), isNotNull);
  });
}
