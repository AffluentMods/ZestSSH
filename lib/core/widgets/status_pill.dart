import 'package:flutter/material.dart';
import '../theme/zest_colors.dart';

/// Three-state status surfaced to the user, derived from the SSH session
/// state of the host (NOT from TCP-ping health). Driven by what the user
/// cares about: "am I connected to this thing right now?".
///
/// * [online]        - live SSH session, connected. Pill reads "Connected".
/// * [connecting]    - session in progress. Pill reads "Connecting…".
/// * [disconnected]  - session exists but the SSH transport dropped /
///                     errored. The user can reconnect from here.
/// * [offline]       - no session at all. The default state for any host
///                     not currently in use.
/// * [error]         - explicit error state (rare; surfaced by the
///                     connection-error dialog rather than the badge).
/// * [unknown]       - legacy fallback. Renders identically to [offline]
///                     so callers that still pass it don't show the
///                     confusing "Unknown" label.
enum HostStatus { online, offline, connecting, error, disconnected, unknown }

/// Base colour for a host status - shared by [StatusPill] and the compact
/// status dot used on Small home-screen cards (Part B).
Color hostStatusColor(HostStatus status) => switch (status) {
      HostStatus.online => ZestColors.statusSuccess,
      HostStatus.connecting => ZestColors.statusWarning,
      HostStatus.disconnected => ZestColors.statusWarning,
      HostStatus.error => ZestColors.statusError,
      HostStatus.offline => ZestColors.statusError,
      HostStatus.unknown => ZestColors.statusError,
    };

class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.status});
  final HostStatus status;

  @override
  Widget build(BuildContext context) {
    final (Color base, String label) = switch (status) {
      HostStatus.online => (ZestColors.statusSuccess, 'Connected'),
      HostStatus.connecting => (ZestColors.statusWarning, 'Connecting…'),
      HostStatus.disconnected => (ZestColors.statusWarning, 'Disconnected'),
      HostStatus.error => (ZestColors.statusError, 'Error'),
      // "Not in use" - single label for both the unconfigured / no-session
      // case and the legacy `unknown` value. "Unknown" was confusing
      // because every host that hadn't been pinged showed it; "Offline"
      // matches the user's mental model of "I'm not using it".
      HostStatus.offline => (ZestColors.statusError, 'Offline'),
      HostStatus.unknown => (ZestColors.statusError, 'Offline'),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: base.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: base, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: base.withValues(alpha: 0.85),
              fontSize: 11,
              fontWeight: FontWeight.w500,
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }
}
