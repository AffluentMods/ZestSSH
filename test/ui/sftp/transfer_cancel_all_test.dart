import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/screens/sftp/transfer_pool.dart';
import 'package:zestssh/ui/screens/sftp/widgets/transfer_queue_panel.dart';

/// Cancel all on a folder transfer stops the whole drop (found in a
/// review). A dropped folder handed every file to a pool of three at once;
/// Cancel all cancelled the rows there were (the three running), each of
/// them leaving the pool woke the next waiting file, and the rest of the
/// folder went on.
void main() {
  test('files still waiting their turn in a cancelled drop never start', () async {
    final pool = TransferPool(3);
    var cancelled = false;
    final started = <int>[];
    final gates = <Completer<void>>[];
    final all = <Future<void>>[];
    for (var i = 0; i < 10; i++) {
      final gate = Completer<void>();
      gates.add(gate);
      all.add(pool.run(cancelled: () => cancelled, () async {
        started.add(i);
        await gate.future;
      }));
    }
    await Future<void>.delayed(Duration.zero);
    expect(started, [0, 1, 2]);
    // Cancel all: the drop is cancelled, and the three running end.
    cancelled = true;
    for (final g in gates.take(3)) {
      g.complete();
    }
    await Future.wait(all);
    expect(started, [0, 1, 2], reason: 'on the old pool all ten ran');
  });

  test('a drop that is not cancelled runs every file, three at a time', () async {
    final pool = TransferPool(3);
    var running = 0;
    var most = 0;
    var ran = 0;
    await Future.wait([
      for (var i = 0; i < 10; i++)
        pool.run(() async {
          running++;
          most = running > most ? running : most;
          await Future<void>.delayed(const Duration(milliseconds: 2));
          running--;
          ran++;
        }),
    ]);
    expect(ran, 10);
    expect(most, 3);
  });

  testWidgets("Cancel all on an operation's row cancels the operation, not only its rows", (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final items = List.generate(3, (i) {
      final t = TransferItem(
        id: 'op-1-$i',
        localPath: 'C:/work/site/f$i.txt',
        remotePath: '/srv/site/f$i.txt',
        fileName: 'f$i.txt',
        direction: TransferDirection.upload,
        totalBytes: 100,
        operationId: 'op-1',
        operationLabel: 'site',
      );
      t.status = TransferStatus.active;
      return t;
    });
    final operations = <String>[];
    final rows = <String>[];
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Column(
          children: [
            const Expanded(child: SizedBox()),
            TransferQueuePanel(transfers: items, onCancel: rows.add, onCancelOperation: operations.add),
          ],
        ),
      ),
    ));
    await tester.tap(find.descendant(of: find.byType(TransferQueuePanel), matching: find.byType(InkWell)).first);
    await tester.pump();
    await tester.tap(find.byIcon(LucideIcons.square).first);
    await tester.pump();
    expect(operations, ['op-1']);
    expect(rows, isEmpty);
    await tester.pump(const Duration(seconds: 2));
  });
}
