import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/screens/this_pc/this_pc_remote_access.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_modal.dart';

/// Reads and changes this PC's Remote Desktop: tests put a stand-in here.
final thisPcRemoteAccessProvider = Provider<ThisPcRemoteAccess>((ref) => ThisPcRemoteAccess());

/// This PC's network addresses: tests put a stand-in here.
final thisPcAddressesProvider = FutureProvider.autoDispose<List<String>>((ref) => thisPcAddresses());

/// This PC's Windows account name: tests put a stand-in here.
final thisPcAccountProvider = Provider<String>((ref) => Platform.environment['USERNAME'] ?? '');

/// Remote access to this PC (4.1, Windows): what another device needs to
/// reach this desktop over Remote Desktop, the button that turns it on (or
/// off), and the address and account to add on the other device.
Future<void> showThisPcRemoteAccess(BuildContext context) => showZestModal<void>(
      context: context,
      size: ZestModalSize.standard,
      child: const ThisPcRemoteAccessDialog(),
    );

class ThisPcRemoteAccessDialog extends ConsumerStatefulWidget {
  const ThisPcRemoteAccessDialog({super.key});

  @override
  ConsumerState<ThisPcRemoteAccessDialog> createState() => _ThisPcRemoteAccessDialogState();
}

class _ThisPcRemoteAccessDialogState extends ConsumerState<ThisPcRemoteAccessDialog> {
  ThisPcState? _state;
  bool _reading = true;
  bool _changing = false;

  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read() async {
    setState(() => _reading = true);
    final s = await ref.read(thisPcRemoteAccessProvider).read();
    if (!mounted) return;
    setState(() {
      _state = s;
      _reading = false;
    });
  }

  Future<void> _change({required bool on}) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _changing = true);
    final result = await ref.read(thisPcRemoteAccessProvider).change(on: on);
    if (!mounted) return;
    setState(() => _changing = false);
    switch (result) {
      case ThisPcChange.done:
        break;
      case ThisPcChange.refused:
        showTopSnackBar(context, l10n.thisPcRefused);
      case ThisPcChange.failed:
        showTopSnackBar(context, l10n.thisPcFailed, isError: true);
    }
    await _read();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final s = _state;
    final canTurnOn = s != null && !s.isHome && !(s.on && s.nla && s.firewallOpen);
    final canTurnOff = s != null && !s.isHome && s.on;
    return ZestDialogShell(
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.monitorSmartphone,
      title: l10n.thisPcTitle,
      maxWidth: 600,
      onClose: () => Navigator.of(context).pop(),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.thisPcIntro, style: TextStyle(fontSize: 13, color: AppColors.v3TextSecondary, height: 1.45)),
          const SizedBox(height: 14),
          if (_reading && s == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
            )
          else if (s == null)
            _Check(ok: false, label: l10n.thisPcRdp, value: l10n.thisPcUnreadable, keyName: 'this-pc-unreadable')
          else ...[
            _Check(
              ok: !s.isHome,
              label: l10n.thisPcEdition,
              value: s.isHome ? l10n.thisPcEditionHome : l10n.thisPcEditionOk(_editionName(s.edition)),
              keyName: 'this-pc-edition',
            ),
            if (!s.isHome) ...[
              _Check(ok: s.on, label: l10n.thisPcRdp, value: s.on ? l10n.thisPcOn : l10n.thisPcOff, keyName: 'this-pc-rdp'),
              _Check(
                ok: s.nla,
                label: l10n.thisPcNla,
                value: s.nla ? l10n.thisPcNlaOn : l10n.thisPcNlaOff,
                keyName: 'this-pc-nla',
              ),
              _Check(
                ok: s.firewallOpen,
                label: l10n.thisPcFirewall,
                value: s.firewallOpen ? l10n.thisPcFirewallOpen(s.port) : l10n.thisPcFirewallClosed,
                keyName: 'this-pc-firewall',
              ),
              const SizedBox(height: 8),
              Text(
                s.ready ? l10n.thisPcReady : l10n.thisPcNotReady,
                key: const ValueKey('this-pc-verdict'),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: s.ready ? AppColors.success : AppColors.v3TextPrimary,
                ),
              ),
              if (canTurnOn || canTurnOff) ...[
                const SizedBox(height: 4),
                Text(l10n.thisPcAdminNote,
                    style: TextStyle(fontSize: 12, color: AppColors.v3TextSecondary, height: 1.4)),
              ],
              if (s.on) ...[const SizedBox(height: 16), _Reach(port: s.port)],
            ],
          ],
        ],
      ),
      primaryKey: const ValueKey('this-pc-turn-on'),
      primaryAction: canTurnOn
          ? (
              label: l10n.thisPcTurnOn,
              icon: LucideIcons.power,
              onPressed: _changing ? null : () => _change(on: true),
            )
          : null,
      secondaryKey: const ValueKey('this-pc-turn-off'),
      secondaryAction: canTurnOff
          ? (
              label: l10n.thisPcTurnOff,
              onPressed: _changing ? null : () => _change(on: false),
            )
          : null,
      tertiaryKey: const ValueKey('this-pc-refresh'),
      tertiaryAction: (
        label: l10n.thisPcRefresh,
        onPressed: _reading || _changing ? null : _read,
      ),
    );
  }

  /// Windows' edition id as people know it.
  static String _editionName(String? id) => switch (id?.toLowerCase()) {
        'professional' || 'professionaln' => 'Windows Pro',
        'professionalworkstation' => 'Windows Pro for Workstations',
        'professionaleducation' => 'Windows Pro Education',
        'enterprise' || 'enterprisen' || 'enterprises' => 'Windows Enterprise',
        'education' || 'educationn' => 'Windows Education',
        final String other when other.startsWith('server') => 'Windows Server',
        _ => id ?? 'Windows',
      };
}

/// One thing checked: a tick or a cross, its name and what was found.
class _Check extends StatelessWidget {
  const _Check({required this.ok, required this.label, required this.value, required this.keyName});

  final bool ok;
  final String label;
  final String value;
  final String keyName;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: ValueKey(keyName),
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(ok ? LucideIcons.checkCircle2 : LucideIcons.xCircle,
                size: 16, color: ok ? AppColors.success : AppColors.warning),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 170,
            child: Text(label, style: TextStyle(fontSize: 13, color: AppColors.v3TextPrimary)),
          ),
          Expanded(
            child: Text(value, style: TextStyle(fontSize: 13, color: AppColors.v3TextSecondary, height: 1.4)),
          ),
        ],
      ),
    );
  }
}

/// The addresses and the account another device adds, and how to reach it
/// from away.
class _Reach extends ConsumerWidget {
  const _Reach({required this.port});

  final int port;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final addresses = ref.watch(thisPcAddressesProvider).valueOrNull ?? const <String>[];
    final user = ref.watch(thisPcAccountProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.thisPcReach,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.v3TextPrimary)),
        const SizedBox(height: 6),
        Text(
          l10n.thisPcReachBody(Redactable.username(user).displayIn(ref)),
          style: TextStyle(fontSize: 12.5, color: AppColors.v3TextSecondary, height: 1.45),
        ),
        const SizedBox(height: 8),
        if (addresses.isEmpty)
          Text(l10n.thisPcNoAddress, style: TextStyle(fontSize: 12.5, color: AppColors.v3TextSecondary))
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final a in addresses)
                ActionChip(
                  key: ValueKey('this-pc-address-$a'),
                  avatar: const Icon(LucideIcons.copy, size: 14),
                  label: Text(
                    Redactable.address(port == 3389 ? a : '$a:$port').displayIn(ref),
                    style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12),
                  ),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: port == 3389 ? a : '$a:$port'));
                    if (context.mounted) showTopSnackBar(context, l10n.thisPcCopied);
                  },
                ),
            ],
          ),
        const SizedBox(height: 10),
        Text(l10n.thisPcAway, style: TextStyle(fontSize: 12, color: AppColors.v3TextSecondary, height: 1.4)),
      ],
    );
  }
}
