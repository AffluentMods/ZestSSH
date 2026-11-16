import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/broadcast/host_checklist.dart';
import 'package:zestssh/providers/terminal_providers.dart' show noRunOnHostsReason;
import 'package:zestssh/features/run/install_key.dart';
import 'package:zestssh/features/run/run_on_hosts.dart';
import 'package:zestssh/features/run/run_on_hosts_view.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_sheet.dart';

/// Opens "Install key on hosts" (3.0) for [key]: the hosts to install it on,
/// then each host's result as it comes. An install that is going is shown as
/// it stands.
/// The key the install on hosts is for (its label), kept beside the run: the
/// dialog opened for another key while one runs shows that run's results,
/// and says whose they are.
final installKeyNameProvider = StateProvider<String?>((ref) => null);

Future<void> showInstallKey(BuildContext context, Identity key) => showZestModal<void>(
      context: context,
      size: ZestModalSize.large,
      child: InstallKeyDialog(keyToInstall: key),
    );

class InstallKeyDialog extends ConsumerStatefulWidget {
  const InstallKeyDialog({super.key, required this.keyToInstall});

  final Identity keyToInstall;

  @override
  ConsumerState<InstallKeyDialog> createState() => _InstallKeyDialogState();
}

class _InstallKeyDialogState extends ConsumerState<InstallKeyDialog> {
  var _picked = <String>{};

  /// Showing the hosts to choose rather than an install's results.
  late bool _settingUp;

  /// The line the key is installed as: the one kept with it, else made from
  /// its private key once that is read (a key made in the app kept none).
  String? _line;

  @override
  void initState() {
    super.initState();
    _settingUp = !(ref.read(installKeyRunProvider)?.running ?? false);
    _line = installLineOf(widget.keyToInstall);
    if (_line == null) unawaited(_makeLine());
  }

  /// The key's line made from its private key; where that cannot be read,
  /// none, and the dialog says the key has no public key.
  Future<void> _makeLine() async {
    String? made;
    try {
      made = await ref.read(identityCrudProvider).publicLineOf(widget.keyToInstall);
    } catch (_) {/* no line to be had */}
    if (mounted) setState(() => _line = installLine(made));
  }

  void _start(List<Connection> hosts, String line) {
    setState(() => _settingUp = false);
    ref.read(installKeyNameProvider.notifier).state = widget.keyToInstall.label;
    unawaited(ref.read(installKeyRunProvider.notifier).run(hosts, kInstallKeyCommand, input: '$line\n'));
  }

  @override
  Widget build(BuildContext context) => _settingUp ? _setup(context) : _results(context);

  String get _keyName => Redactable.keyName(widget.keyToInstall.label).displayIn(ref);

  /// The name of the key whose install is on screen: the one it was started
  /// for, which is not this dialog's while another key's install runs.
  String _runKeyName() => Redactable.keyName(ref.watch(installKeyNameProvider) ?? widget.keyToInstall.label).displayIn(ref);

  Widget _setup(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final all = ref.watch(connectionsWithDetailsProvider).valueOrNull ?? const <ConnectionWithDetails>[];
    final isPro = ref.watch(isProProvider);
    final hosts = [for (final c in all) if (_picked.contains(c.connection.id)) c.connection];
    final overLimit = !isPro && hosts.length > runOnHostsFreeLimit;
    final line = _line;
    final running = ref.watch(installKeyRunProvider)?.running ?? false;

    // A phone's sheet scrolls as one, the keyboard taking the height of a list
    // of its own.
    final sheet = ZestSheetScope.of(context);
    final checklist = HostChecklist(
      picked: _picked,
      onChanged: (picked) => setState(() => _picked = picked),
      keyPrefix: 'install',
      autofocus: false,
      // It runs as a run on hosts does, on SSH hosts alone.
      unavailable: noRunOnHostsReason,
    );

    return ZestDialogShell(
      size: ZestModalSize.large,
      tone: ZestDialogTone.info,
      icon: LucideIcons.keyRound,
      title: l10n.installKeyTitle,
      subtitle: l10n.installKeySubtitle(_keyName),
      bodyScrolls: sheet,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (sheet) checklist else Flexible(child: checklist),
          const SizedBox(height: 8),
          if (line == null)
            _Note(
              key: const ValueKey('install-no-key'),
              icon: LucideIcons.alertTriangle,
              color: ZestColors.statusWarning,
              text: l10n.zestKeysNoPublicKey,
            )
          else if (overLimit)
            _Note(
              key: const ValueKey('install-limit'),
              icon: LucideIcons.info,
              color: ZestColors.statusWarning,
              text: l10n.runOnHostsLimit(runOnHostsFreeLimit),
            )
          else if (hosts.isEmpty)
            _Note(
              key: const ValueKey('install-pick'),
              icon: LucideIcons.info,
              color: ZestColors.textTertiary,
              text: l10n.installKeyPickOne,
            ),
          const SizedBox(height: 6),
          _Note(icon: LucideIcons.terminal, color: ZestColors.textTertiary, text: l10n.installKeyUnix),
        ],
      ),
      primaryAction: (
        label: l10n.installKeyRun(hosts.length),
        icon: LucideIcons.upload,
        onPressed: line != null && hosts.isNotEmpty && !overLimit && !running ? () => _start(hosts, line) : null,
      ),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
    );
  }

  Widget _results(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final run = ref.watch(installKeyRunProvider);
    if (run == null) return _setup(context);
    final notifier = ref.read(installKeyRunProvider.notifier);
    final keyName = _runKeyName();
    final through = run.hosts.where((h) => h.over).length;
    final have = run.hosts.where(keyInstalledOn).length;
    final notHave = run.hosts.where((h) => h.over && !keyInstalledOn(h)).length;

    return ZestDialogShell(
      size: ZestModalSize.large,
      tone: ZestDialogTone.info,
      icon: LucideIcons.keyRound,
      title: l10n.installKeyTitle,
      subtitle: l10n.installKeySubtitle(keyName),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  run.running ? l10n.runOnHostsProgress(through, run.hosts.length) : l10n.installKeySummary(have, notHave),
                  key: const ValueKey('install-summary'),
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: ZestColors.textSecondary),
                ),
              ),
              TextButton.icon(
                key: const ValueKey('install-copy'),
                onPressed: () => Clipboard.setData(ClipboardData(text: installKeyReport(run, l10n, keyName))),
                icon: const Icon(LucideIcons.copy, size: 14),
                label: Text(l10n.runOnHostsCopyAll, style: const TextStyle(fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final h in run.hosts)
            HostRunRow(key: ValueKey('install-row-${h.host.id}'), run: h, words: keyInstallWords, ok: keyInstalledOn),
        ],
      ),
      primaryAction: run.running
          ? (label: l10n.runOnHostsStop, icon: LucideIcons.square, onPressed: notifier.stop)
          : (
              label: l10n.installKeyAgain,
              icon: LucideIcons.rotateCcw,
              onPressed: notHave > 0 ? () => unawaited(notifier.again()) : null,
            ),
      tertiaryAction: (label: l10n.close, onPressed: () => Navigator.of(context).pop()),
    );
  }
}

/// An install as text: for "Copy all results", each host with how it ended,
/// and what it printed as errors where it did not end well.
String installKeyReport(HostsRun run, AppLocalizations l10n, String keyName) {
  final out = StringBuffer('${l10n.installKeyTitle}: $keyName\n');
  for (final h in run.hosts) {
    out.write('\n== ${h.host.label.isNotEmpty ? h.host.label : h.host.host} (${h.host.host}): ${keyInstallWords(h, l10n)}\n');
    if (h.state == HostRunState.failed) {
      final said = hostRunFailureSaid(h, l10n);
      out.write('${said.title}: ${said.description}\n');
    }
    if (!keyInstalledOn(h) && h.errors.isNotEmpty) {
      out.write(h.errors.endsWith('\n') ? h.errors : '${h.errors}\n');
    }
  }
  return out.toString();
}

class _Note extends StatelessWidget {
  const _Note({super.key, required this.icon, required this.color, required this.text});

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(fontSize: 12, color: color))),
        ],
      );
}
