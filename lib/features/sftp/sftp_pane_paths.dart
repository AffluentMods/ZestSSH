import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Where one SFTP pane pair is browsing (remember-last-folder spec, section
/// 1 "pane state"): the remote pane's directory, the username it was seen
/// under, and the local pane's directory. Device-local, never synced; it
/// rides inside the tab snapshot so a restart (or a saved workspace) brings
/// each pane back to its own folder: three panes on one host in three
/// directories restore to three paths.
///
/// Paths are stored in their canonical `realpath` form once the debounced
/// writer has settled them; until then they hold whatever the pane navigated
/// to, which is only ever a hint for the resolver anyway.
class SftpPanePaths {
  const SftpPanePaths({
    this.remotePath,
    this.remoteUser,
    this.localPath,
    this.connectionId,
  });

  final String? remotePath;
  final String? remoteUser;
  final String? localPath;

  /// The host the remote pane is on, so "Forget last folder" can drop every
  /// pane of that host without walking the session table.
  final String? connectionId;

  bool get isEmpty => remotePath == null && localPath == null;

  SftpPanePaths copyWith({
    String? remotePath,
    String? remoteUser,
    String? localPath,
    String? connectionId,
    bool clearRemote = false,
  }) =>
      SftpPanePaths(
        remotePath: clearRemote ? null : (remotePath ?? this.remotePath),
        remoteUser: clearRemote ? null : (remoteUser ?? this.remoteUser),
        localPath: localPath ?? this.localPath,
        connectionId: connectionId ?? this.connectionId,
      );

  Map<String, dynamic> toJson() => {
        if (remotePath != null) 'remotePath': remotePath,
        if (remoteUser != null) 'remoteUser': remoteUser,
        if (localPath != null) 'localPath': localPath,
        if (connectionId != null) 'connectionId': connectionId,
      };

  static SftpPanePaths? fromJson(Object? raw) {
    if (raw is! Map) return null;
    String? str(String k) {
      final v = raw[k];
      return v is String && v.isNotEmpty ? v : null;
    }

    final out = SftpPanePaths(
      remotePath: str('remotePath'),
      remoteUser: str('remoteUser'),
      localPath: str('localPath'),
      connectionId: str('connectionId'),
    );
    return out.isEmpty ? null : out;
  }

  @override
  bool operator ==(Object other) =>
      other is SftpPanePaths &&
      other.remotePath == remotePath &&
      other.remoteUser == remoteUser &&
      other.localPath == localPath &&
      other.connectionId == connectionId;

  @override
  int get hashCode =>
      Object.hash(remotePath, remoteUser, localPath, connectionId);

  @override
  String toString() =>
      'SftpPanePaths(remote: $remotePath as $remoteUser, local: $localPath)';
}

/// Live pane state keyed by the SFTP leaf's SESSION id (one SFTP pane pair
/// per session, so three panes on one host are three keys). Written by the
/// dual-pane screen on every settled navigation, read by the snapshot
/// builder at close and by the leaf when it mounts after a restore.
class SftpPanePathsNotifier extends StateNotifier<Map<String, SftpPanePaths>> {
  SftpPanePathsNotifier() : super(const {});

  SftpPanePaths? get(String sessionId) => state[sessionId];

  /// Seed a restored pane before it mounts (the leaf reads it as its
  /// initial paths).
  void seed(String sessionId, SftpPanePaths paths) {
    if (paths.isEmpty) return;
    state = {...state, sessionId: paths};
  }

  void setRemote(
    String sessionId, {
    required String path,
    String? user,
    String? connectionId,
  }) {
    final cur = state[sessionId] ?? const SftpPanePaths();
    final next = cur.copyWith(
      remotePath: path,
      remoteUser: user,
      connectionId: connectionId,
    );
    if (next == cur) return;
    state = {...state, sessionId: next};
  }

  void setLocal(String sessionId, String path) {
    final cur = state[sessionId] ?? const SftpPanePaths();
    final next = cur.copyWith(localPath: path);
    if (next == cur) return;
    state = {...state, sessionId: next};
  }

  void forgetSession(String sessionId) {
    if (!state.containsKey(sessionId)) return;
    state = {...state}..remove(sessionId);
  }

  /// "Forget last folder" (spec 4): drop the remote memory of every pane on
  /// [connectionId]. Local pane paths are unrelated to the host and stay.
  void forgetHost(String connectionId) {
    var changed = false;
    final next = <String, SftpPanePaths>{};
    for (final e in state.entries) {
      if (e.value.connectionId == connectionId && e.value.remotePath != null) {
        changed = true;
        final stripped = e.value.copyWith(clearRemote: true);
        if (!stripped.isEmpty) next[e.key] = stripped;
      } else {
        next[e.key] = e.value;
      }
    }
    if (changed) state = next;
  }
}

final sftpPanePathsProvider =
    StateNotifierProvider<SftpPanePathsNotifier, Map<String, SftpPanePaths>>(
        (_) => SftpPanePathsNotifier());
