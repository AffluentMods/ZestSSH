import 'dart:io';

import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/sftp_delete_hold_provider.dart';
import 'package:zestssh/providers/sftp_transfers_provider.dart';
import 'package:zestssh/services/sftp_error_messages.dart';
import 'package:zestssh/services/sftp_service.dart';
import 'package:zestssh/services/sftp_sync_service.dart';
import 'package:zestssh/services/transfer_cancel_token.dart';
import 'package:zestssh/ui/screens/sftp/widgets/pane_file_source.dart';
import 'package:zestssh/ui/screens/sftp/widgets/transfer_queue_panel.dart';

/// A file transfer, a delete, a permission change or a new folder that fails
/// says why in the app's language, on its row in Activity, with a report to
/// copy that names no file (3.0). They showed the raw
/// error, `<name>: <error>` for one of several, and only on hover over the
/// progress bar, with nothing to copy.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));

  setUp(() {
    L10nGlobal.update(en);
    SharedPreferences.setMockInitialValues({});
  });

  SftpStatusError denied() => SftpStatusError(SftpStatusCode.permissionDenied, 'Permission denied');

  TransferItem upload(String id, String name) => TransferItem(
        id: id,
        localPath: 'C:/demo/$name',
        remotePath: '/srv/demo/$name',
        fileName: name,
        direction: TransferDirection.upload,
        totalBytes: 2048,
      );

  group('what a failure says', () {
    test('one that fails says why about its file, and its report names none', () {
      final error = denied();
      final up = upload('u1', 'contracts')..failWith(error, stack: StackTrace.current, op: SftpOp.upload);
      expect(up.status, TransferStatus.failed);
      expect(up.failure, same(error));
      expect(up.errorMessage, "Permission denied: your account can't write \"contracts\" on the server.");
      final report = up.errorReport!;
      expect(report, startsWith('ZestSSH error details\n'));
      expect(report, contains("What: Permission denied: your account can't write the item on the server.\n"));
      expect(report, contains('Where: Files: upload\n'));
      expect(report, contains('Error: $error\n'));
      expect(report, contains('Stack:'));
      expect(report, isNot(contains('contracts')));

      // A download is said as one, and where it failed is a download.
      final down = TransferItem(
        id: 'd1',
        localPath: 'C:/demo/contracts',
        remotePath: '/srv/demo/contracts',
        fileName: 'contracts',
        direction: TransferDirection.download,
        totalBytes: 10,
      )..failWith(error, op: SftpOp.download);
      expect(down.errorMessage, "Permission denied: your account can't read \"contracts\" on the server.");
      expect(down.errorReport, contains('Where: Files: download\n'));
      expect(down.errorReport, isNot(contains('Stack:')));

      // An operation names the folder it was about, not its row's title.
      final mkdir = TransferItem.operation(id: 'm1', kind: SftpOperationKind.mkdir, title: 'Creating "reports"')
        ..failWith(error, op: SftpOp.mkdir, name: 'reports');
      expect(mkdir.errorMessage, "Permission denied: your account can't create \"reports\" on the server.");
      expect(mkdir.errorReport, contains('Where: Files: mkdir\n'));
      expect(mkdir.errorReport, isNot(contains('reports')));
    });

    test('one of several says itself, several say how many, and the report has what was thrown for each', () {
      final error = denied();
      final quota = SftpStatusError(SftpStatusCode.failure, 'Disk quota exceeded');

      final one = TransferItem.operation(id: 'c1', kind: SftpOperationKind.chmod, title: 'Setting permissions')
        ..failWithAll([(name: 'contracts', error: error)], several: '1 of 3 items failed', op: SftpOp.chmod);
      expect(one.status, TransferStatus.failed);
      expect(one.errorMessage, "Permission denied: your account can't change the permissions of \"contracts\" on the server.");
      expect(one.errorReport,
          contains("What: Permission denied: your account can't change the permissions of the item on the server.\n"));
      expect(one.errorReport, contains('Where: Files: chmod\n'));
      expect(one.errorReport, contains('Details:\n  $error\n'));
      expect(one.errorReport, isNot(contains('contracts')));

      final two = TransferItem.operation(id: 'c2', kind: SftpOperationKind.chmod, title: 'Setting permissions')
        ..failWithAll([(name: 'contracts', error: error), (name: 'invoices', error: quota)],
            several: '2 of 3 items failed', op: SftpOp.chmod);
      expect(two.errorMessage, '2 of 3 items failed');
      expect(two.errorReport, contains('What: 2 of 3 items failed\n'));
      expect(two.errorReport, contains('Details:\n  $error\n  $quota\n'));
      expect(two.errorReport, isNot(contains('contracts')));
      expect(two.errorReport, isNot(contains('invoices')));
    });

    test('a lost connection is said as such, however many it failed', () {
      final lost = StateError('Connection closed');
      final item = TransferItem.operation(id: 'x1', kind: SftpOperationKind.delete, title: 'Deleting')
        ..failWithAll([(name: 'contracts', error: lost)],
            several: 'Not deleted, connection lost', op: SftpOp.delete, oneByItself: false);
      expect(item.errorMessage, 'Not deleted, connection lost');
      expect(item.errorReport, contains('What: Not deleted, connection lost\n'));
      expect(item.errorReport, contains('Details:\n  $lost\n'));
    });

    test('in the app\'s language', () {
      L10nGlobal.update(lookupAppLocalizations(const Locale('de')));
      addTearDown(() => L10nGlobal.update(en));
      final up = upload('u2', 'contracts')..failWith(denied(), op: SftpOp.upload);
      expect(up.errorMessage,
          sftpErrorMessage(denied(), name: 'contracts', op: SftpOp.upload, l10n: lookupAppLocalizations(const Locale('de'))));
      expect(up.errorMessage, isNot(sftpErrorMessage(denied(), name: 'contracts', op: SftpOp.upload, l10n: en)));
    });
  });

  testWidgets('a failed row says why and copies its report; a cancelled one has neither', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    final failed = upload('u1', 'contracts')..failWith(denied(), op: SftpOp.upload);
    final cancelled = upload('u2', 'invoices')..status = TransferStatus.cancelled;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Column(children: [
          const Expanded(child: SizedBox()),
          TransferQueuePanel(transfers: [failed, cancelled], onRetry: (_) {}),
        ]),
      ),
    ));
    // Open the panel (its title bar is the first InkWell inside it).
    await tester.tap(find.descendant(of: find.byType(TransferQueuePanel), matching: find.byType(InkWell)).first);
    await tester.pump();

    final why = find.byKey(const ValueKey('transfer-failure-u1'));
    expect(why, findsOneWidget);
    expect(tester.widget<Text>(why).data, "Permission denied: your account can't write \"contracts\" on the server.");
    expect(find.byKey(const ValueKey('transfer-failure-u2')), findsNothing);

    // One copy button: the failed row's.
    expect(find.byTooltip('Copy details'), findsOneWidget);
    expect(find.byIcon(LucideIcons.copy), findsOneWidget);
    await tester.tap(find.byTooltip('Copy details'));
    await tester.pump();
    expect(copied, failed.errorReport);
    expect(find.byTooltip('Copied'), findsOneWidget);
    expect(find.byIcon(LucideIcons.check), findsOneWidget);

    // The tick goes back after a moment.
    await tester.pump(const Duration(seconds: 3));
    expect(find.byTooltip('Copy details'), findsOneWidget);
    expect(find.byIcon(LucideIcons.check), findsNothing);
  });

  group('a delete, once its hold is over', () {
    late ProviderContainer container;
    late SftpTransfersNotifier transfers;
    late SftpDeleteHoldManager holds;
    late _Source source;

    setUp(() {
      container = ProviderContainer();
      transfers = container.read(sftpTransfersProvider.notifier);
      holds = container.read(sftpDeleteHoldProvider);
      source = _Source();
    });
    tearDown(() => container.dispose());

    PaneFileEntry file(String name) =>
        PaneFileEntry(name: name, path: '/srv/demo/$name', isDirectory: false, size: 1);

    Future<TransferItem> commit(String id, List<PaneFileEntry> targets) async {
      transfers.add(TransferItem.operation(
          id: id, kind: SftpOperationKind.delete, title: 'Deleting', status: TransferStatus.holding));
      holds.hold(DeleteHold(
        opId: id,
        sessionId: 's1',
        hostLabel: 'web-01',
        source: source,
        targets: targets,
        deadline: DateTime.now().add(const Duration(hours: 1)),
        connectionLostText: 'Not deleted, connection lost',
        skippedText: (n) => '$n skipped',
        failedText: (n) => '$n not deleted',
      ));
      await holds.commitNow(id);
      return transfers.findById(id)!;
    }

    test('one that fails says why about its file', () async {
      final error = denied();
      source.deleteErrors['/srv/demo/contracts'] = error;
      final item = await commit('h1', [file('contracts'), file('notes')]);
      expect(item.status, TransferStatus.failed);
      expect(item.errorMessage, "Permission denied: your account can't delete \"contracts\" on the server.");
      expect(item.errorReport, contains("What: Permission denied: your account can't delete the item on the server.\n"));
      expect(item.errorReport, contains('Where: Files: delete\n'));
      expect(item.errorReport, contains('Details:\n  $error\n'));
      expect(item.errorReport, isNot(contains('contracts')));
      expect(source.deleted, ['/srv/demo/notes']);
    });

    test('several that fail say how many, each in the report', () async {
      final error = denied();
      final quota = SftpStatusError(SftpStatusCode.failure, 'Read-only file system');
      source.deleteErrors['/srv/demo/contracts'] = error;
      source.deleteErrors['/srv/demo/invoices'] = quota;
      final item = await commit('h2', [file('contracts'), file('invoices')]);
      expect(item.errorMessage, '2 not deleted');
      expect(item.errorReport, contains('What: 2 not deleted\n'));
      expect(item.errorReport, contains('Details:\n  $error\n  $quota\n'));
    });

    test('a lost connection says so, with what was thrown in the report', () async {
      final lost = StateError('Connection closed');
      source.deleteErrors['/srv/demo/contracts'] = lost;
      final item = await commit('h3', [file('contracts'), file('notes')]);
      expect(item.errorMessage, 'Not deleted, connection lost');
      expect(item.errorReport, contains('What: Not deleted, connection lost\n'));
      expect(item.errorReport, contains('Details:\n  $lost\n'));
      // (Nothing after it was tried.)
      expect(source.deleted, isEmpty);
    });
  });

  group('a folder sync', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('zestssh_sync_failures_');
    });
    tearDown(() async => dir.delete(recursive: true));

    SyncPlanItem up(String name) {
      final f = File('${dir.path}${Platform.pathSeparator}$name')..writeAsStringSync('demo');
      return SyncPlanItem(
          localPath: f.path, remotePath: '/srv/demo/$name', action: SyncAction.upload, size: 4, reason: 'new');
    }

    test('keeps each file that failed with what was thrown', () async {
      final sftp = _Sftp();
      final error = denied();
      final a = up('contracts.txt');
      final b = up('notes.txt');
      sftp.uploadErrors[a.remotePath] = error;
      final summary = await SftpSyncService(sftp).runSync(plan: [a, b], options: const SftpSyncOptions());
      expect(summary.failed, 1);
      expect(summary.failures, hasLength(1));
      expect(summary.failures.single.path, a.localPath);
      expect(summary.failures.single.error, same(error));
      expect(summary.errors, ['${a.localPath}: $error']);
      expect(sftp.uploaded, [b.remotePath]);
    });

    test('and each remote file it could not delete', () async {
      final sftp = _Sftp();
      final error = denied();
      const gone = SyncPlanItem(
          localPath: '', remotePath: '/srv/demo/old.txt', action: SyncAction.deleteRemote, size: 0, reason: 'remote only');
      const kept = SyncPlanItem(
          localPath: '', remotePath: '/srv/demo/older.txt', action: SyncAction.deleteRemote, size: 0, reason: 'remote only');
      sftp.deleteErrors[gone.remotePath] = error;
      final summary = await SftpSyncService(sftp)
          .runSync(plan: [gone, kept], options: const SftpSyncOptions(deleteRemoteOnly: true));
      expect(summary.failed, 1);
      expect(summary.failures.single.path, gone.remotePath);
      expect(summary.failures.single.error, same(error));
      expect(sftp.deleted, [kept.remotePath]);
    });
  });
}

/// A source whose deletes fail as told; the rest is unused.
class _Source extends PaneFileSource {
  final Map<String, Object> deleteErrors = {};
  final List<String> deleted = [];

  @override
  Future<void> deleteFile(String path) async {
    final e = deleteErrors[path];
    if (e != null) throw e;
    deleted.add(path);
  }

  @override
  String get sourceId => 'demo';
  @override
  bool get isPosix => true;
  @override
  Future<String> homeDirectory() async => '/srv/demo';
  @override
  Future<List<PaneFileEntry>> list(String path, {bool includeHidden = true}) async => const [];
  @override
  Future<PaneFileEntry?> stat(String path) async => null;
  @override
  Future<bool> exists(String path) async => true;
  @override
  Future<void> mkdir(String path, {bool recursive = false}) async {}
  @override
  Future<void> rename(String oldPath, String newPath) async {}
  @override
  Future<void> deleteDirectoryRecursive(String path,
      {void Function(String deletedPath)? onDeleted, bool Function()? isCancelled}) async {}
  @override
  Future<int> countEntriesRecursive(String path) async => 0;
  @override
  Future<void> chmod(String path, int mode) async {}
  @override
  Future<void> chmodRecursive(String path, int mode,
      {void Function(String path)? onDone, bool Function()? isCancelled}) async {}
  @override
  Future<Uint8List> readBytes(String path, {int? maxBytes}) async => Uint8List(0);
  @override
  Future<void> writeBytes(String path, Uint8List bytes) async {}
  @override
  Future<void> downloadFile(String remotePath, String localPath,
      {PaneTransferProgress? onProgress, TransferCancelToken? cancelToken, int? maxBytes, bool bulk = false}) async {}
  @override
  Future<void> uploadFile(String localPath, String remotePath,
      {PaneTransferProgress? onProgress, TransferCancelToken? cancelToken, bool bulk = false}) async {}
}

/// An SFTP connection whose uploads and deletes fail as told; what a sync
/// reads back after an upload is not there (it proves nothing either way).
class _Sftp implements SftpService {
  final Map<String, Object> uploadErrors = {};
  final Map<String, Object> deleteErrors = {};
  final List<String> uploaded = [];
  final List<String> deleted = [];

  @override
  Future<void> uploadFileFromPath(
    String localPath,
    String remotePath, {
    SftpProgressCallback? onProgress,
    TransferCancelToken? cancelToken,
    bool preserveTimestamp = true,
    bool preservePermissions = true,
    bool useTransferChannel = false,
  }) async {
    final e = uploadErrors[remotePath];
    if (e != null) throw e;
    uploaded.add(remotePath);
  }

  @override
  Future<void> deleteFile(String remotePath) async {
    final e = deleteErrors[remotePath];
    if (e != null) throw e;
    deleted.add(remotePath);
  }

  @override
  Future<void> createDirectoryRecursive(String remotePath) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('not in this test');
}
