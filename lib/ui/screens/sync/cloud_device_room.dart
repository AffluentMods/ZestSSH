import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/cloud/cloud_failure.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/features/orchards/widgets/orchard_step_up.dart' show ItsYou, StepUpWindow, confirmOrSignIn;
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_scroll_fade.dart';
import 'package:zestssh/utils/logger.dart';

// ZestSSH Cloud syncs up to seven devices for one person.
// Past that, sync pauses on this device, and the way on is
// to sign out a device no longer used: this lists the account's other
// signed-in devices, each with Sign out, right where the pause is said, and
// syncs again once one is gone (removing a device no longer used
// should be simple).

/// Opens the list of the account's signed-in devices to sign one out and
/// make room for this one.
Future<void> showCloudDeviceRoom(BuildContext context) => showZestModal<void>(
      context: context,
      size: ZestModalSize.standard,
      child: const CloudDeviceRoomDialog(),
    );

class CloudDeviceRoomDialog extends ConsumerStatefulWidget {
  const CloudDeviceRoomDialog({super.key});

  @override
  ConsumerState<CloudDeviceRoomDialog> createState() => _CloudDeviceRoomDialogState();
}

class _CloudDeviceRoomDialogState extends ConsumerState<CloudDeviceRoomDialog> {
  List<DeviceSessionInfo>? _devices;

  /// What stopped the list, while it could not be read.
  Object? _failed;

  /// The device being signed out, while it is.
  String? _busy;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _failed = null);
    try {
      final list = await ref.read(deviceSessionServiceProvider).api.list();
      if (mounted) setState(() => _devices = [for (final d in list) if (!d.current) d]);
    } catch (e) {
      AppLogger.warning('Making room on ZestSSH Cloud: the devices could not be listed ($e)');
      if (mounted) setState(() => _failed = e);
    }
  }

  static String nameOf(AppLocalizations l10n, DeviceSessionInfo d) => switch (d.platform) {
        'windows' => 'Windows',
        'macos' => 'macOS',
        'linux' => 'Linux',
        'android' => 'Android',
        'ios' => 'iOS',
        _ => l10n.devicesUnknownDevice,
      };

  Future<void> _signOut(DeviceSessionInfo device) async {
    final l10n = AppLocalizations.of(context)!;
    final api = ref.read(deviceSessionServiceProvider).api;
    final ok = await ZestConfirmDialog.show(
      context,
      // An ordinary question: what it does is said, and nothing is deleted
      // (3.4, nothing amber).
      tone: ZestDialogTone.neutral,
      title: l10n.devicesSignOutConfirmTitle,
      body: l10n.devicesSignOutConfirmBody(nameOf(l10n, device)),
      confirmLabel: l10n.devicesSignOut,
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = device.id);
    try {
      try {
        await api.signOut(device.id);
      } on DeviceSessionsException catch (e) {
        // ZestSSH Cloud wants a sign-in from the last few minutes first, or a
        // passkey's confirmation.
        if (!e.needsRecentSignIn || !mounted) rethrow;
        final shown = await confirmOrSignIn(context, ref, window: StepUpWindow.account, askFirst: false);
        if (shown != ItsYou.confirmed) return;
        await api.signOut(device.id);
      }
      if (!mounted) return;
      showTopSnackBar(context, l10n.devicesSignedOutOne(nameOf(l10n, device)), isSuccess: true);
      // Room made: sync again now, the pause after the refusals lifted.
      unawaited(ref.read(autoSyncServiceProvider).retryAfterFix());
      Navigator.of(context).pop();
    } catch (e) {
      AppLogger.warning('Making room on ZestSSH Cloud: a device could not be signed out ($e)');
      if (mounted) {
        showTopSnackBar(context, cloudStopped(l10n, e) ?? l10n.devicesActionFailed, isError: true, details: '$e');
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final devices = _devices;
    final Widget list;
    if (_failed != null) {
      // What stopped it, where it was ZestSSH Cloud or the way to it.
      final said = cloudStopped(l10n, _failed!) ?? l10n.devicesActionFailed;
      list = Text(said, style: TextStyle(fontSize: 13, color: ZestTokens.statusCritical));
    } else if (devices == null) {
      list = const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
      );
    } else if (devices.isEmpty) {
      // Where Sign out everywhere is: Settings, Account, on a computer and
      // on a phone or tablet alike since 4.0 (a computer's page was Account
      // and security; each its own words, as the 3.0 docs check had them).
      final phone = defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;
      list = Text(phone ? l10n.syncDeviceRoomEmptyPhone : l10n.syncDeviceRoomEmpty,
          key: const ValueKey('device-room-empty'),
          style: TextStyle(fontSize: 13, height: 1.45, color: ZestTokens.textSecondary));
    } else {
      list = Container(
        decoration: BoxDecoration(
          color: ZestTokens.surfaceRaisedAlt,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: ZestTokens.borderSubtle),
        ),
        child: Column(
          children: [
            for (var i = 0; i < devices.length; i++) ...[
              if (i > 0) Divider(height: 1, color: ZestTokens.borderSubtle),
              _row(l10n, devices[i]),
            ],
          ],
        ),
      );
    }
    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: ZestDialogTone.info,
      icon: LucideIcons.monitorSmartphone,
      title: l10n.syncDeviceRoomTitle,
      body: ZestScrollFade(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.syncDeviceRoomBody, style: TextStyle(fontSize: 13, height: 1.5, color: ZestTokens.textSecondary)),
            const SizedBox(height: 14),
            list,
          ],
        ),
      ),
      primaryAction: _failed != null ? (label: l10n.retry, icon: LucideIcons.rotateCw, onPressed: _load) : null,
      secondaryAction: (label: l10n.close, onPressed: _busy != null ? null : () => Navigator.of(context).pop()),
    );
  }

  Widget _row(AppLocalizations l10n, DeviceSessionInfo d) {
    final when = d.createdAt == null ? null : l10n.devicesSignedInOn(DateFormat.yMMMd(l10n.localeName).format(d.createdAt!));
    return Padding(
      key: ValueKey('device-room-${d.id}'),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Row(
        children: [
          Icon(d.isPhone ? LucideIcons.smartphone : LucideIcons.monitor, size: 16, color: ZestTokens.textSecondary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(nameOf(l10n, d), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
                if (when != null) Text(when, style: TextStyle(fontSize: 12, color: ZestTokens.textTertiary)),
              ],
            ),
          ),
          OutlinedButton(
            key: ValueKey('device-room-sign-out-${d.id}'),
            onPressed: _busy != null ? null : () => unawaited(_signOut(d)),
            style: OutlinedButton.styleFrom(
              foregroundColor: ZestTokens.statusCritical,
              side: BorderSide(color: ZestTokens.statusCritical.withValues(alpha: 0.55)),
            ),
            child: _busy == d.id
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(l10n.devicesSignOut),
          ),
        ],
      ),
    );
  }
}
