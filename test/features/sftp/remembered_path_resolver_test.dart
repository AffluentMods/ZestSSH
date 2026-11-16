import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/zest_ssh_core.dart';
import 'package:zestssh/features/sftp/remembered_path_resolver.dart';
import 'package:zestssh/services/transfer_cancel_token.dart';
import 'package:zestssh/ui/screens/sftp/widgets/pane_file_source.dart';

/// A POSIX source whose directories are a fixed set; listing anything else
/// throws the SFTP status the server would. Counts round trips.
class _FakeSource extends PaneFileSource {
  _FakeSource(this.listable, {this.denied = const {}});

  final Set<String> listable;
  final Set<String> denied;
  final List<String> probes = [];

  @override
  String get sourceId => 'fake';
  @override
  bool get isPosix => true;
  @override
  Future<String> homeDirectory() async => '/home/user';

  @override
  Future<List<PaneFileEntry>> list(String path,
      {bool includeHidden = true}) async {
    probes.add(path);
    if (denied.contains(path)) {
      throw SftpStatusError(SftpStatusCode.permissionDenied, 'Permission denied');
    }
    if (!listable.contains(path)) {
      throw SftpStatusError(SftpStatusCode.noSuchFile, 'No such file');
    }
    return const [];
  }

  // Unused surface.
  @override
  Future<PaneFileEntry?> stat(String path) async => null;
  @override
  Future<bool> exists(String path) async => listable.contains(path);
  @override
  Future<void> mkdir(String path, {bool recursive = false}) async {}
  @override
  Future<void> rename(String oldPath, String newPath) async {}
  @override
  Future<void> deleteFile(String path) async {}
  @override
  Future<void> deleteDirectoryRecursive(String path,
      {void Function(String deletedPath)? onDeleted,
      bool Function()? isCancelled}) async {}
  @override
  Future<int> countEntriesRecursive(String path) async => 0;
  @override
  Future<void> chmod(String path, int mode) async {}
  @override
  Future<void> chmodRecursive(String path, int mode,
      {void Function(String path)? onDone, bool Function()? isCancelled}) async {}
  @override
  Future<Uint8List> readBytes(String path, {int? maxBytes}) async =>
      Uint8List(0);
  @override
  Future<void> writeBytes(String path, Uint8List bytes) async {}
  @override
  Future<void> downloadFile(String remotePath, String localPath,
      {PaneTransferProgress? onProgress,
      TransferCancelToken? cancelToken,
      int? maxBytes,
      bool bulk = false}) async {}
  @override
  Future<void> uploadFile(String localPath, String remotePath,
      {PaneTransferProgress? onProgress,
      TransferCancelToken? cancelToken,
      bool bulk = false}) async {}
}

void main() {
  group('resolveRemembered (spec section 3)', () {
    test('an existing listable path resolves exactly, one round trip', () async {
      final src = _FakeSource({'/srv/www/site'});
      final r = await resolveRemembered(src, '/srv/www/site');
      expect(r.exact, isTrue);
      expect(r.path, '/srv/www/site');
      expect(r.failure, isNull);
      expect(src.probes, ['/srv/www/site']);
    });

    test('a gone path walks up to the nearest listable ancestor', () async {
      final src = _FakeSource({'/srv/www', '/srv', '/'});
      final r = await resolveRemembered(src, '/srv/www/site/releases');
      expect(r.path, '/srv/www');
      expect(r.climbed, 2);
      expect(r.failure, RememberedFailure.gone);
      expect(src.probes, ['/srv/www/site/releases', '/srv/www/site', '/srv/www']);
    });

    test('exists but not listable reports no-access and still climbs', () async {
      final src = _FakeSource({'/var', '/'}, denied: {'/var/log/private'});
      final r = await resolveRemembered(src, '/var/log/private');
      expect(r.path, '/var');
      expect(r.failure, RememberedFailure.noAccess);
    });

    test('at most maxClimb climbs, so at most maxClimb + 1 round trips',
        () async {
      final src = _FakeSource({'/'});
      final r = await resolveRemembered(src, '/a/b/c/d/e/f/g', maxClimb: 4);
      expect(r.unreachable, isTrue);
      expect(src.probes.length, 5);
      expect(src.probes.last, '/a/b/c');
    });

    test('stops at the root and never loops', () async {
      final src = _FakeSource({});
      final r = await resolveRemembered(src, '/x', maxClimb: 10);
      expect(r.unreachable, isTrue);
      expect(src.probes, ['/x', '/']);
    });

    test('never throws, whatever the source does', () async {
      final src = _ThrowingSource();
      final r = await resolveRemembered(src, '/anything');
      expect(r.unreachable, isTrue);
      expect(r.failure, RememberedFailure.gone);
    });
  });

  group('classifyListFailure', () {
    test('SFTP permission denied is no-access, everything else is gone', () {
      expect(
          classifyListFailure(
              SftpStatusError(SftpStatusCode.permissionDenied, 'x')),
          RememberedFailure.noAccess);
      expect(classifyListFailure(SftpStatusError(SftpStatusCode.noSuchFile, 'x')),
          RememberedFailure.gone);
      expect(classifyListFailure(Exception('boom')), RememberedFailure.gone);
    });
    test('local EACCES is no-access, ENOENT is gone', () {
      expect(
          classifyListFailure(const FileSystemException(
              'Directory listing failed', '/x', OSError('denied', 13))),
          RememberedFailure.noAccess);
      expect(
          classifyListFailure(const FileSystemException(
              'Directory listing failed', '/x', OSError('missing', 2))),
          RememberedFailure.gone);
    });
  });
}

class _ThrowingSource extends _FakeSource {
  _ThrowingSource() : super({});
  @override
  Future<List<PaneFileEntry>> list(String path,
      {bool includeHidden = true}) async {
    throw StateError('channel closed');
  }
}
