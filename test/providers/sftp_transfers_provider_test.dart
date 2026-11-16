import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/providers/sftp_transfers_provider.dart';
import 'package:zestssh/ui/screens/sftp/widgets/transfer_queue_panel.dart';

/// The Activity queue publishes COALESCED snapshots (regression guard for the
/// folder-upload UI lag).
///
/// A folder drop fires several mutations per file (add, progress, complete,
/// verify) and every publish rebuilds every watcher with a full O(N) pass. With
/// per-mutation publishing, a 16k-file tree meant ~64k rebuilds x 16k items on
/// the main isolate. These tests pin the contract that bounds that: a burst of
/// mutations yields ONE publish, reads through [findById] stay immediate, and
/// user actions (remove) still publish synchronously.
void main() {
  TransferItem item(String id) => TransferItem(
        id: id,
        localPath: '/local/$id',
        remotePath: '/remote/$id',
        fileName: id,
        direction: TransferDirection.upload,
        totalBytes: 10,
      );

  test('a burst of adds + touches coalesces into a single publish', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    var publishes = 0;
    c.listen<List<TransferItem>>(
      sftpTransfersProvider,
      (_, __) => publishes++,
      fireImmediately: false,
    );
    final n = c.read(sftpTransfersProvider.notifier);

    // 100 files x (add + progress touch) = 200 mutations in one turn.
    for (var i = 0; i < 100; i++) {
      n.add(item('f$i'));
      n.touch();
    }

    // Nothing published yet (still inside the coalescing window)...
    expect(publishes, 0);
    expect(c.read(sftpTransfersProvider), isEmpty);
    // ...but the data is already the source of truth for lookups.
    expect(n.findById('f42'), isNotNull);

    await Future<void>.delayed(const Duration(milliseconds: 150));

    // ONE publish for 200 mutations, carrying all 100 items.
    expect(publishes, 1);
    expect(c.read(sftpTransfersProvider), hasLength(100));
  });

  test('a later touch after the window publishes again (not lost)', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    var publishes = 0;
    c.listen<List<TransferItem>>(
      sftpTransfersProvider,
      (_, __) => publishes++,
      fireImmediately: false,
    );
    final n = c.read(sftpTransfersProvider.notifier);

    n.add(item('a'));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(publishes, 1);

    n.findById('a')!.status = TransferStatus.completed;
    n.touch();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(publishes, 2);
    expect(c.read(sftpTransfersProvider).single.status,
        TransferStatus.completed);
  });

  test('remove publishes immediately (user action, no coalescing delay)',
      () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final n = c.read(sftpTransfersProvider.notifier);
    n.add(item('x'));
    n.add(item('y'));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(c.read(sftpTransfersProvider), hasLength(2));

    n.remove('x');
    // Synchronous: no await.
    expect(c.read(sftpTransfersProvider).map((t) => t.id), ['y']);
    expect(n.findById('x'), isNull);
  });

  test('sftpHasActiveTransferProvider reflects the published snapshot',
      () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final n = c.read(sftpTransfersProvider.notifier);
    expect(c.read(sftpHasActiveTransferProvider), isFalse);
    n.add(item('z')..status = TransferStatus.active);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(c.read(sftpHasActiveTransferProvider), isTrue);
  });
}
