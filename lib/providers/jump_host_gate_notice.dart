import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Raised by the connect path when a Free-tier user's jump chain was NOT
/// dialed (jump-host routing is a Squeezed feature) and the connection fell
/// back to direct. `app.dart` listens, shows it once per [key] with an Upgrade
/// action, then clears it, so a gated chain never fails silently.
///
/// The connect path raises this on every gated connect; the once-only memory
/// lives with the listener (persisted through SettingsService), which keeps
/// this a plain signal.
class JumpHostGateNotice {
  const JumpHostGateNotice({
    required this.key,
    required this.hostLabel,
    required this.fromOverride,
    this.networkName,
  });

  /// One-time key, `<host id>:<network name or "base">`, so each host and
  /// source is explained exactly once.
  final String key;

  /// The host as the user names it (label, or host address when unlabelled).
  final String hostLabel;

  /// True when the skipped chain came from a per-network override; false when
  /// it was the base host's Connect Via (a value that can arrive by sync or
  /// import even though the editor locks the field).
  final bool fromOverride;

  /// The network whose override set the chain; null for the base chain.
  final String? networkName;
}

final jumpHostGateNoticeProvider =
    StateProvider<JumpHostGateNotice?>((ref) => null);
