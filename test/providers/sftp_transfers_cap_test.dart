import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/sftp_transfers_provider.dart';
import 'package:zestssh/ui/screens/sftp/widgets/transfer_queue_panel.dart';

/// The transfer list keeps a bounded number of finished rows: every file
/// ever sent stayed until the person cleared the list, and the whole list
/// is copied at each publish. The newest finished rows stay, of a folder
/// larger than the limit too, and a folder that loses rows keeps its count.
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
      operationLabel: op == null ? null : 'website',
    );
    t.status = status;
    return t;
  }

  test('finished rows past the cap go, oldest first, row by row; a running drop keeps every row; failed ones stay',
      () {
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
    // 1,099 finished: the 99 oldest go (old-7 failed is not one of them).
    expect(n.findById('old-0'), isNull, reason: 'the oldest go');
    expect(n.findById('old-99'), isNull);
    expect(n.findById('old-100'), isNotNull, reason: 'the newest of the old drop stay');
    expect(n.findById('old-599'), isNotNull);
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
    // The old drop's finished rows are all gone now; its failed row stays,
    // with the 599 files that were sent counted on it.
    final old = n.state.where((t) => t.operationId == 'old').toList();
    expect(old.map((t) => t.id), ['old-7']);
    expect(old.single.fileCount, 600);
    expect(old.single.earlierCompleted, 599);
  });

  test('one folder of more than the limit keeps its newest rows, and its folder row its count and bytes', () {
    final n = SftpTransfersNotifier();
    addTearDown(n.dispose);
    const cap = SftpTransfersNotifier.maxFinishedRows;
    for (var i = 0; i < cap + 500; i++) {
      n.add(item('f-$i', op: 'site'));
    }
    n.touchNow();
    final kept = n.state.where((t) => t.operationId == 'site').toList();
    expect(kept, hasLength(cap), reason: 'the newest finished rows up to the limit, not none');
    expect(kept.first.id, 'f-500');
    expect(kept.last.id, 'f-${cap + 499}');
    // What the folder row adds up: every file of the folder, and its bytes.
    expect(kept.fold<int>(0, (sum, t) => sum + t.fileCount), cap + 500);
    expect(kept.fold<int>(0, (sum, t) => sum + t.earlierCompleted), 500);
    expect(kept.fold<int>(0, (sum, t) => sum + t.totalBytes + t.earlierTotalBytes), (cap + 500) * 10);

    // Dismissing the row that counts the earlier ones takes one file off the count.
    n.remove(kept.first.id);
    final left = n.state.where((t) => t.operationId == 'site').toList();
    expect(left.fold<int>(0, (sum, t) => sum + t.fileCount), cap + 499);

    // Clear completed: nothing of it is left, nor counted.
    n.add(item('f-failed', op: 'site', status: TransferStatus.failed));
    n.clearCompleted();
    final failed = n.state.where((t) => t.operationId == 'site').toList();
    expect(failed.map((t) => t.id), ['f-failed']);
    expect(failed.single.fileCount, 1);
  });

  testWidgets('the folder row of such a folder says all of its files', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final n = SftpTransfersNotifier();
    addTearDown(n.dispose);
    const all = SftpTransfersNotifier.maxFinishedRows + 500;
    for (var i = 0; i < all; i++) {
      n.add(item('f-$i', op: 'site'));
    }
    n.touchNow();
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Column(children: [const Expanded(child: SizedBox()), TransferQueuePanel(transfers: n.state)]),
      ),
    ));
    // Open the panel.
    await tester.tap(find.descendant(of: find.byType(TransferQueuePanel), matching: find.byType(InkWell)).first);
    await tester.pump();
    expect(find.text('website'), findsOneWidget);
    expect(find.textContaining('$all / $all files'), findsOneWidget);
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
