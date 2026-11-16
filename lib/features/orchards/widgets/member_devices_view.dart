import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/widgets/orchard_device_dialogs.dart';
import 'package:zestssh/features/orchards/widgets/orchard_step_up.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/features/orchards/widgets/team_admin_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_empty_state.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/ui/widgets/zest_status.dart';
import 'package:zestssh/utils/logger.dart';

/// A member's approved devices (3.0), as the Orchard's record lists
/// them: each by the short name made from its key, this device marked, and
/// Remove where this account may take an approval back from this device.
/// On one's own row, a device that is not approved says so, and asks (or,
/// an owner's first one, approves itself).
Future<void> showMemberDevices(
  BuildContext context,
  WidgetRef ref,
  OrchardSummary orchard, {
  required String uid,
  required String name,
  required bool isMe,
}) {
  final l10n = AppLocalizations.of(context)!;
  return ZestDialogShell.showModal<void>(
    context,
    size: ZestModalSize.standard,
    tone: ZestDialogTone.info,
    icon: LucideIcons.monitorSmartphone,
    title: l10n.memberDevicesTitle,
    subtitle: name,
    body: MemberDevicesView(orchard: orchard, uid: uid, name: name, isMe: isMe),
    primaryAction: (label: l10n.close, onPressed: () => Navigator.of(context).pop(), icon: null),
  );
}

/// Approves this device as an owner's own first one in [orchardId], asking
/// for a recent sign-in when the server wants one, and says how it went.
Future<void> approveThisDevice(BuildContext context, WidgetRef ref, String orchardId) async {
  final l10n = AppLocalizations.of(context)!;
  try {
    final done = await withRecentSignIn(
      context,
      ref,
      () => ref.read(orchardServiceProvider).approveThisDevice(orchardId),
      summary: (what: l10n.stepUpApproveThisDevice, effects: [l10n.stepUpApproveDeviceEffect]),
    );
    if (!done || !context.mounted) return;
    ref.read(orchardListVersionProvider.notifier).state++;
    showTopSnackBar(context, l10n.deviceApprovedThis, isSuccess: true);
  } catch (e) {
    AppLogger.warning('Trusted devices: this device was not approved ($e)');
    if (context.mounted) showTopSnackBar(context, orchardChangeErrorMessage(e, l10n), isError: true, details: '$e');
  }
}

class MemberDevicesView extends ConsumerStatefulWidget {
  const MemberDevicesView({
    super.key,
    required this.orchard,
    required this.uid,
    required this.name,
    required this.isMe,
    this.header = false,
  });

  final OrchardSummary orchard;
  final String uid;

  /// Heads the list with its section's name: in a page or panel that has
  /// none for it (a dialog's title names it).
  final bool header;

  /// The member's name as the page shows it.
  final String name;

  /// The member is the account signed in here.
  final bool isMe;

  @override
  ConsumerState<MemberDevicesView> createState() => _MemberDevicesViewState();
}

class _MemberDevicesViewState extends ConsumerState<MemberDevicesView> {
  /// The key of the device being removed, or '' while this device approves
  /// itself.
  String? _busy;

  String get _id => widget.orchard.id;

  Future<void> _approveThis() async {
    setState(() => _busy = '');
    try {
      await approveThisDevice(context, ref, _id);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _remove(MemberDevice device) async {
    final l10n = AppLocalizations.of(context)!;
    final go = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.memberDeviceRemoveTitle(device.code),
      body: device.isThis
          ? l10n.memberDeviceRemoveThisBody
          : widget.isMe
              ? l10n.memberDeviceRemoveOwnBody
              : l10n.memberDeviceRemoveBody(widget.name),
      confirmLabel: l10n.memberDeviceRemove,
    );
    if (go != true || !mounted) return;
    setState(() => _busy = device.key);
    try {
      final done = await withRecentSignIn(
        context,
        ref,
        () => ref.read(orchardServiceProvider).removeDevice(_id, uid: device.uid, deviceKey: device.key),
        summary: (what: l10n.stepUpRemoveDevice(device.code), effects: [l10n.stepUpRemoveDeviceEffect]),
      );
      if (!done || !mounted) return;
      ref.read(orchardListVersionProvider.notifier).state++;
      showTopSnackBar(context, l10n.memberDeviceRemoved, isSuccess: true);
    } catch (e) {
      AppLogger.warning('Trusted devices: a device was not removed ($e)');
      if (mounted) showTopSnackBar(context, orchardChangeErrorMessage(e, l10n), isError: true, details: '$e');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final devices = ref.watch(memberDevicesProvider((orchardId: _id, uid: widget.uid)));
    final standing = widget.isMe ? ref.watch(deviceStandingProvider(_id)).valueOrNull : null;
    final listed = devices.valueOrNull;
    final thisCode = standing?.thisCode;
    // This account, on a device the record does not list: one callout with
    // the one thing to do, above the list (it said so twice before, and the
    // list under it read "No approved device." on its own).
    final held = standing != null && !standing.approved && thisCode != null;
    final approvesItself = standing?.canApproveItself ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (held) ...[
          TeamCallout(
            key: const ValueKey('member-devices-this'),
            tone: TeamTone.warning,
            icon: LucideIcons.shieldAlert,
            title: approvesItself ? l10n.memberDevicesThisFirst(thisCode) : l10n.memberDevicesThisNot(thisCode),
            body: approvesItself ? null : l10n.deviceAskIntro,
            action: teamButton(
              key: const ValueKey('member-devices-this-action'),
              kind: TeamButtonKind.primary,
              icon: approvesItself ? LucideIcons.shieldCheck : LucideIcons.send,
              busy: _busy == '',
              label: approvesItself ? l10n.deviceApproveThis : l10n.deviceAskAction,
              onPressed: _busy != null
                  ? null
                  : approvesItself
                      ? _approveThis
                      : () => showDeviceAsk(context, ref, widget.orchard),
            ),
          ),
          const SizedBox(height: 20),
        ],
        // Under the callout, or where the page around has no heading of its
        // own for the list (the member panel's section).
        if (held || widget.header) ZestSectionHeader(label: l10n.memberDevicesTitle),
        if (listed == null)
          devices.hasError
              ? ZestEmptyRow(message: l10n.memberDevicesLoadFailed)
              : const Padding(
                  padding: EdgeInsets.symmetric(vertical: 10),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
                )
        else if (listed.isEmpty)
          _DevicesBox(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const TeamIconTile(icon: LucideIcons.monitorOff),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(l10n.memberDevicesNone,
                        key: const ValueKey('member-devices-none'),
                        style: TextStyle(fontSize: 13, color: ZestTokens.textSecondary)),
                  ),
                ],
              ),
            ),
          )
        else
          _DevicesBox(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < listed.length; i++) ...[
                  if (i > 0) Divider(height: 1, thickness: 1, color: ZestTokens.borderSubtle),
                  _deviceRow(listed[i], l10n),
                ],
              ],
            ),
          ),
        const SizedBox(height: 8),
        Text(l10n.memberDevicesHelp, style: TextStyle(fontSize: 12, height: 1.45, color: ZestTokens.textTertiary)),
      ],
    );
  }

  /// One approved device: what the record knows of it (its code, made from
  /// its key, and whether it is this one), and Remove where this account may.
  Widget _deviceRow(MemberDevice d, AppLocalizations l10n) {
    return ConstrainedBox(
      key: ValueKey('member-device-${d.code}'),
      constraints: const BoxConstraints(minHeight: 56),
      child: Padding(
        padding: const EdgeInsets.only(left: 12, right: 6),
        child: Row(
          children: [
            const TeamIconTile(icon: LucideIcons.monitorSmartphone),
            const SizedBox(width: 12),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      d.code,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 13, color: ZestTokens.textPrimary),
                    ),
                  ),
                  if (d.isThis) ...[
                    const SizedBox(width: 10),
                    ZestStatusPill(
                        kind: ZestStatusKind.neutral, icon: LucideIcons.monitorCheck, label: l10n.memberDevicesThis),
                  ],
                ],
              ),
            ),
            if (_busy == d.key)
              const SizedBox(
                width: 44,
                height: 44,
                child: Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
              )
            else if (d.canRemove)
              TeamIconAction(
                key: ValueKey('member-device-remove-${d.code}'),
                icon: LucideIcons.trash2,
                tooltip: l10n.memberDeviceRemove,
                danger: true,
                onPressed: _busy != null ? null : () => _remove(d),
              )
            else
              const SizedBox(width: 6),
          ],
        ),
      ),
    );
  }
}

/// The devices, together in one box set apart from the page around it.
class _DevicesBox extends StatelessWidget {
  const _DevicesBox({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: ZestTokens.surfaceRaisedAlt,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: ZestTokens.borderSubtle),
        ),
        child: child,
      );
}
