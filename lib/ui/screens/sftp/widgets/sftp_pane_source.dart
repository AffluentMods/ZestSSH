import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/ftps/ftps_pane_file_source.dart';
import 'package:zestssh/services/sftp_service.dart';

/// Where one pane in the dual-pane SFTP screen is browsing.
///
/// Three live shapes:
///  - [LocalPaneSource] - the OS filesystem on this machine.
///  - [RemotePaneSource] - a connected SFTP host (carries the live service).
///  - [DisconnectedPaneSource] - a host the user previously selected that
///    has since dropped. The pane shows a "Click to reconnect" placeholder
///    but preserves the connection id and last path.
///
/// The source PICKER moved to the SFTP rail header - the
/// old in-file `SftpSourceDropdown` is gone; this file now only carries the
/// descriptor types the pane + rail render.
sealed class SftpPaneSource {
  const SftpPaneSource();

  /// Short label rendered in the picker trigger / header. A descriptor has
  /// no context, so its words come from the app-wide localizations. (Its icon
  /// is the screen's to draw: a saved host's own, HostGlyph.)
  String get label;

  /// The host it is on, as its label, for naming it (a delete's question, an
  /// editor tab); null for this computer's own files.
  String? get hostName => switch (this) {
        RemotePaneSource(:final hostLabel) => hostLabel,
        FtpsPaneSource(:final hostLabel) => hostLabel,
        DisconnectedPaneSource(:final hostLabel) => hostLabel,
        LocalPaneSource() => null,
      };
}

class LocalPaneSource extends SftpPaneSource {
  const LocalPaneSource();

  @override
  String get label => gl10n.connectionPickerLocalFiles;
}

class RemotePaneSource extends SftpPaneSource {
  final String sessionId;
  final String hostLabel;
  final SftpService service;

  /// `user@host:port` of the server behind [service], when the caller knows
  /// it. Stable across sessions and unique per server, unlike [hostLabel]
  /// (two connections can share a label). The folder-sync manifest is keyed
  /// on this so two servers never share a cache; null falls back to the label.
  final String? serverId;

  const RemotePaneSource({
    required this.sessionId,
    required this.hostLabel,
    required this.service,
    this.serverId,
  });

  @override
  String get label => hostLabel;
}

/// A connected FTPS host (3.4): its files over FTP with TLS, through [files].
/// Not a [RemotePaneSource]: what needs SSH (a terminal here, a search or a
/// tail run on the host, free space) is not offered on it.
class FtpsPaneSource extends SftpPaneSource {
  final String sessionId;
  final String hostLabel;
  final FtpsPaneFileSource files;

  const FtpsPaneSource({required this.sessionId, required this.hostLabel, required this.files});

  @override
  String get label => hostLabel;
}

class DisconnectedPaneSource extends SftpPaneSource {
  /// Connection id (not session id - sessions are gone after disconnect).
  final String connectionId;
  final String hostLabel;
  final String? lastPath;

  const DisconnectedPaneSource({
    required this.connectionId,
    required this.hostLabel,
    this.lastPath,
  });

  @override
  String get label => gl10n.sftpHostDisconnected(hostLabel);
}
