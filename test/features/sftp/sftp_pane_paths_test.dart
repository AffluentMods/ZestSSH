import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/sftp/remote_path_sanitizer.dart';
import 'package:zestssh/features/sftp/sftp_pane_paths.dart';
import 'package:zestssh/models/pane_tree.dart';
import 'package:zestssh/models/saved_tab_group.dart';

void main() {
  group('SftpPanePaths', () {
    test('round-trips through JSON and drops empties', () {
      const p = SftpPanePaths(
        remotePath: '/srv/www',
        remoteUser: 'deploy',
        localPath: r'C:\Users\me\site',
        connectionId: 'c1',
      );
      final back = SftpPanePaths.fromJson(jsonDecode(jsonEncode(p.toJson())));
      expect(back, p);
      expect(SftpPanePaths.fromJson({}), isNull);
      expect(SftpPanePaths.fromJson('nope'), isNull);
      expect(SftpPanePaths.fromJson({'remotePath': ''}), isNull);
    });

    test('the provider keys panes by session and forgets by host', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = c.read(sftpPanePathsProvider.notifier);
      n.setRemote('s1', path: '/a', user: 'u', connectionId: 'host-A');
      n.setRemote('s2', path: '/b', user: 'u', connectionId: 'host-A');
      n.setRemote('s3', path: '/c', user: 'u', connectionId: 'host-B');
      n.setLocal('s1', '/home/me');
      // Three panes, three paths: pane state is per pane, not per host.
      expect(c.read(sftpPanePathsProvider)['s1']!.remotePath, '/a');
      expect(c.read(sftpPanePathsProvider)['s2']!.remotePath, '/b');

      n.forgetHost('host-A');
      final after = c.read(sftpPanePathsProvider);
      expect(after['s1']!.remotePath, isNull, reason: 'remote memory dropped');
      expect(after['s1']!.localPath, '/home/me', reason: 'local memory kept');
      expect(after.containsKey('s2'), isFalse, reason: 'nothing left to keep');
      expect(after['s3']!.remotePath, '/c', reason: 'other host untouched');
    });

    test('a same-value write does not churn the state', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = c.read(sftpPanePathsProvider.notifier);
      n.setRemote('s1', path: '/a', user: 'u', connectionId: 'h');
      final before = c.read(sftpPanePathsProvider);
      n.setRemote('s1', path: '/a', user: 'u', connectionId: 'h');
      expect(identical(before, c.read(sftpPanePathsProvider)), isTrue);
    });
  });

  group('TabSnapshot pane paths', () {
    test('ride in the snapshot keyed by leaf id and survive JSON', () {
      final leaf = PaneLeaf(sessionIds: const ['conn-1'], type: 'sftp');
      final snap = TabSnapshot(
        paneTreeOfConnIds: leaf,
        panePaths: {
          leaf.id: const SftpPanePaths(
              remotePath: '/var/www', remoteUser: 'www', localPath: '/tmp'),
        },
      );
      final back = TabSnapshot.fromJson(
          jsonDecode(jsonEncode(snap.toJson())) as Map<String, dynamic>)!;
      expect(back.panePaths[leaf.id]?.remotePath, '/var/www');
      expect(back.panePaths[leaf.id]?.localPath, '/tmp');
      // An old snapshot without the field still loads.
      final legacy = TabSnapshot.fromJson({'paneTree': leaf.toJson()})!;
      expect(legacy.panePaths, isEmpty);
    });

    test('mapPaneTreeIds keeps leaf ids only when asked', () {
      final leaf = PaneLeaf(sessionIds: const ['sid-1'], type: 'sftp');
      final kept = mapPaneTreeIds(leaf, (_) => 'conn-1', keepIds: true)!;
      final fresh = mapPaneTreeIds(leaf, (_) => 'conn-1')!;
      expect((kept as PaneLeaf).id, leaf.id);
      expect((fresh as PaneLeaf).id, isNot(leaf.id));
    });
  });

  group('remote path sanitizer (sync boundary)', () {
    test('accepts an absolute POSIX path and canonicalises separators', () {
      expect(sanitizeRemotePath('/srv//www/'), '/srv/www');
      expect(sanitizeRemotePath('/'), '/');
      expect(sanitizeRemotePath(' /home/me '), '/home/me');
    });
    test('rejects relative, empty, non-string, oversized and control-laden', () {
      expect(sanitizeRemotePath('srv/www'), isNull);
      expect(sanitizeRemotePath(''), isNull);
      expect(sanitizeRemotePath(42), isNull);
      expect(sanitizeRemotePath('/${'a' * 5000}'), isNull);
      expect(sanitizeRemotePath('/srv/\u202ewww'), '/srv/www');
      expect(sanitizeRemotePath('/srv/w\x00ww'), '/srv/www');
    });
    test('usernames are trimmed, stripped and capped', () {
      expect(sanitizeRemoteUser(' deploy\n'), 'deploy');
      expect(sanitizeRemoteUser(''), isNull);
      expect(sanitizeRemoteUser('x' * 300), isNull);
    });
  });
}
