import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/features/onboarding/data/onboarding_import.dart';
import 'package:zestssh/features/onboarding/data/ssh_config_source.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';

/// Reviewable import of parsed SSH-config entries: the user sees exactly what
/// was found, can deselect any of it, and sees what couldn't be parsed before
/// anything is written. On confirm it creates the selected connections.
///
/// Designed to sit inside a bounded box (it uses an [Expanded] list), e.g. the
/// onboarding import step or a dedicated screen body.
class SshConfigReview extends ConsumerStatefulWidget {
  const SshConfigReview({
    super.key,
    required this.result,
    required this.onImported,
  });

  final SshConfigScanResult result;

  /// Called after connections are created, with the outcome so the caller can
  /// report success / partial failure and move on.
  final void Function(SshImportOutcome outcome) onImported;

  @override
  ConsumerState<SshConfigReview> createState() => _SshConfigReviewState();
}

class _SshConfigReviewState extends ConsumerState<SshConfigReview> {
  late final Set<int> _selected;
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    // Everything importable is selected by default.
    _selected = {
      for (var i = 0; i < widget.result.entries.length; i++) i,
    };
  }

  Future<void> _import() async {
    if (_selected.isEmpty || _importing) return;
    setState(() => _importing = true);
    final entries = [
      for (final i in _selected) widget.result.entries[i],
    ];
    final outcome = await importSshEntries(ref, entries, l10n: AppLocalizations.of(context)!);
    if (!mounted) return;
    setState(() => _importing = false);
    widget.onImported(outcome);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final entries = widget.result.entries;
    final skipped = widget.result.skipped;

    if (entries.isEmpty) {
      return _NoneImportable(skipped: skipped);
    }

    final allSelected = _selected.length == entries.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              l10n.sshImportHostsFound(entries.length),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.onSurface,
              ),
            ),
            const Spacer(),
            TextButton(
              onPressed: () => setState(() {
                if (allSelected) {
                  _selected.clear();
                } else {
                  _selected
                    ..clear()
                    ..addAll(List.generate(entries.length, (i) => i));
                }
              }),
              child: Text(allSelected
                  ? l10n.sshImportDeselectAll
                  : l10n.sshImportSelectAll),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Expanded(
          child: ListView(
            children: [
              for (var i = 0; i < entries.length; i++)
                _EntryTile(
                  entry: entries[i],
                  selected: _selected.contains(i),
                  onChanged: (v) => setState(() {
                    if (v) {
                      _selected.add(i);
                    } else {
                      _selected.remove(i);
                    }
                  }),
                ),
              if (skipped.isNotEmpty) ...[
                const SizedBox(height: 16),
                _SkippedSection(skipped: skipped),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed:
              _selected.isEmpty || _importing ? null : _import,
          icon: _importing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(LucideIcons.checkCheck),
          label: Text(l10n.sshImportButtonCount(_selected.length)),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.brandOrange,
            minimumSize: const Size(double.infinity, 48),
          ),
        ),
      ],
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.entry,
    required this.selected,
    required this.onChanged,
  });

  final OnboardingSshEntry entry;
  final bool selected;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final user = entry.user;
    final jump = entry.proxyJumpHost;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: selected
          ? AppColors.brandOrange.withValues(alpha: 0.08)
          : AppColors.surface,
      child: CheckboxListTile(
        value: selected,
        onChanged: (v) => onChanged(v ?? false),
        activeColor: AppColors.brandOrange,
        // Recording mode: the alias is a host label, the subtitle a
        // `user@host:port` (plus the jump host) composed from typed parts,
        // the same as the settings SSH-config importer.
        title: RedactedText(
          Redactable.host(entry.alias),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Consumer(
          builder: (context, ref, _) => Text(
            '${user != null ? '${Redactable.username(user).displayIn(ref)}@' : ''}'
            '${Redactable.address('${entry.hostname}:${entry.port}').displayIn(ref)}'
            '${jump != null ? '  ·  via ${Redactable.address(jump).displayIn(ref)}' : ''}',
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          ),
        ),
        secondary:
            Icon(LucideIcons.server, color: AppColors.accentInk),
      ),
    );
  }
}

class _SkippedSection extends StatelessWidget {
  const _SkippedSection({required this.skipped});
  final List<SshConfigSkip> skipped;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    String reasonText(SshSkipReason r) => switch (r) {
          SshSkipReason.wildcard => l10n.sshImportSkipReasonWildcard,
          SshSkipReason.host => l10n.sshImportSkipReasonHost,
          SshSkipReason.port => l10n.sshImportSkipReasonPort,
        };

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.divider, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.info,
                  size: 16,
                  color: AppColors.warning.withValues(alpha: 0.9)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.sshImportReviewSkipped(skipped.length),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.onSurface,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final s in skipped)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // A skipped entry's label is still a host alias.
                  RedactedText(
                    Redactable.host(s.label),
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      reasonText(s.reason),
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.textSecondary
                            .withValues(alpha: 0.75),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _NoneImportable extends StatelessWidget {
  const _NoneImportable({required this.skipped});
  final List<SshConfigSkip> skipped;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Icon(LucideIcons.searchX,
            size: 44, color: AppColors.textSecondary.withValues(alpha: 0.5)),
        const SizedBox(height: 12),
        Text(
          l10n.sshImportReviewNoneImportable,
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textSecondary),
        ),
        if (skipped.isNotEmpty) ...[
          const SizedBox(height: 16),
          _SkippedSection(skipped: skipped),
        ],
      ],
    );
  }
}
