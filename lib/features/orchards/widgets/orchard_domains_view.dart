import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/domains/orchard_domains_api.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/widgets/orchard_step_up.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/features/orchards/widgets/team_admin_ui.dart';
import 'package:zestssh/l10n/time_ago.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/utils/error_report.dart';

// An Orchard's domains (3.0): owners claim the domains their
// company's addresses use and prove each one with a DNS TXT record, which
// ZestSSH Cloud looks up (and checks again every day). Company sign-in (SSO)
// and directory sync work for proven domains only.

/// The Domains screen of the Orchard [orchardId] (owners).
Future<void> showOrchardDomains(BuildContext context, WidgetRef ref, String orchardId) {
  final l10n = AppLocalizations.of(context)!;
  return ZestDialogShell.showModal<void>(
    context,
    size: ZestModalSize.standard,
    tone: ZestDialogTone.info,
    icon: LucideIcons.globe,
    title: l10n.orchardDomains,
    subtitle: l10n.orchardDomainsSubtitle,
    body: OrchardDomainsView(orchardId: orchardId),
    primaryAction: (label: l10n.close, onPressed: () => Navigator.of(context).pop(), icon: null),
  );
}

/// What went wrong with a domain, in words a person can act on.
String domainErrorMessage(Object error, AppLocalizations l10n) {
  if (error is DomainNotProven) return l10n.orchardDomainNotYet;
  if (error is OrchardServerException) {
    switch (error.code) {
      case 'domain-taken':
        return l10n.orchardDomainTaken;
      case 'domain-limit':
        return l10n.orchardDomainLimit(20);
      case 'invalid-request':
        return l10n.orchardRulesDomainInvalid;
      case 'rate-limited':
        return l10n.orchardDomainRateLimited;
    }
  }
  return orchardErrorMessage(error, l10n);
}

class OrchardDomainsView extends ConsumerStatefulWidget {
  const OrchardDomainsView({super.key, required this.orchardId, this.onRead});

  final String orchardId;

  /// The domains as last read (the Sign-in page's steps unlock by them).
  final ValueChanged<List<OrchardDomain>>? onRead;

  @override
  ConsumerState<OrchardDomainsView> createState() => _OrchardDomainsViewState();
}

class _OrchardDomainsViewState extends ConsumerState<OrchardDomainsView> {
  final _field = TextEditingController();
  List<OrchardDomain>? _domains;
  String? _busy;
  String? _error;

  /// What failed, for Copy details (the page showed the sentence alone;
  /// the error went to the log).
  String? _errorReport;

  void _failed(Object e, StackTrace st, String where) {
    if (!mounted) return;
    final said = domainErrorMessage(e, AppLocalizations.of(context)!);
    setState(() {
      _error = said;
      _errorReport = ErrorReport.build(what: said, where: 'Orchard domains: $where', error: e, stack: st);
    });
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  OrchardDomainsApi get _api => ref.read(orchardDomainsApiProvider);

  Future<void> _load() async {
    try {
      final list = await _api.list(widget.orchardId);
      if (!mounted) return;
      setState(() => _domains = list);
      widget.onRead?.call(list);
    } catch (e, st) {
      AppLogger.warning('Orchard domains: could not be read ($e)');
      _failed(e, st, 'reading them');
    }
  }

  Future<void> _run(String key, Future<void> Function() action) async {
    setState(() {
      _busy = key;
      _error = null;
      _errorReport = null;
    });
    try {
      await action();
    } catch (e, st) {
      AppLogger.warning('Orchard domains: a change was not made ($e)');
      _failed(e, st, 'a change ($key)');
    } finally {
      if (mounted) setState(() => _busy = null);
      await _load();
    }
  }

  Future<void> _add() async {
    final domain = _field.text.trim();
    if (domain.isEmpty) return;
    await _run('add', () async {
      await _api.claim(widget.orchardId, domain);
      _field.clear();
    });
  }

  Future<void> _check(OrchardDomain d) async {
    final l10n = AppLocalizations.of(context)!;
    await _run(d.domain, () async {
      final proven = await _api.verify(widget.orchardId, d.domain);
      if (mounted && proven.verified) showTopSnackBar(context, l10n.orchardDomainProvenToast(proven.domain), isSuccess: true);
    });
  }

  Future<void> _remove(OrchardDomain d) async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await ZestConfirmDialog.show(
      context,
      // Company sign-in stops at this domain: red.
      tone: ZestDialogTone.destructive,
      title: l10n.orchardDomainRemoveTitle(d.domain),
      body: l10n.orchardDomainRemoveBody,
      confirmLabel: l10n.orchardDomainRemove,
    );
    if (ok != true || !mounted) return;
    await _run(d.domain, () async {
      // A proven domain is part of who can sign in: a recent sign-in first.
      if (await withRecentSignIn(context, ref, () => _api.drop(widget.orchardId, d.domain),
              summary: (what: l10n.stepUpDropDomain(d.domain), effects: const [])) &&
          mounted) {
        showTopSnackBar(context, l10n.orchardDomainRemoved, isSuccess: true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final domains = _domains;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (domains == null && _error == null)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 1.6))),
          )
        else if (domains != null && domains.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(l10n.orchardDomainsEmpty, style: TextStyle(fontSize: 12.5, color: ZestTokens.textSecondary)),
          )
        else if (domains != null)
          for (final d in domains)
            _DomainRow(
              key: ValueKey('domain-${d.domain}'),
              domain: d,
              busy: _busy == d.domain,
              onCheck: _busy == null ? () => _check(d) : null,
              onRemove: _busy == null ? () => _remove(d) : null,
            ),
        // The field at the button's height, Add beside it.
        Row(
          children: [
            Expanded(
              child: TeamField(
                fieldKey: const ValueKey('domain-field'),
                controller: _field,
                hint: domains == null || domains.isEmpty ? l10n.orchardDomainsAddHint : l10n.orchardDomainsAddAnother,
                keyboardType: TextInputType.url,
                onSubmitted: (_) => _add(),
              ),
            ),
            const SizedBox(width: 8),
            teamButton(
              key: const ValueKey('domain-add'),
              icon: LucideIcons.plus,
              label: l10n.orchardDomainsAdd,
              busy: _busy == 'add',
              onPressed: _busy == null ? _add : null,
            ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!,
              key: const ValueKey('domain-error'),
              style: TextStyle(fontSize: 12, height: 1.4, color: ZestTokens.statusCritical)),
          if (_errorReport != null)
            Align(alignment: Alignment.centerLeft, child: CopyDetailsButton(detail: _errorReport!)),
        ],
      ],
    );
  }
}

/// A claimed domain: its name and where it stands, and until it is proven
/// the TXT record to publish (each part to copy), Check now, and when it
/// was last looked for.
class _DomainRow extends StatelessWidget {
  const _DomainRow({super.key, required this.domain, required this.busy, this.onCheck, this.onRemove});

  final OrchardDomain domain;
  final bool busy;
  final VoidCallback? onCheck;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final d = domain;
    final at = d.verifiedAt;
    final txt = d.txt;
    final checked = d.checkedAt;
    final pill = d.verified
        ? _Pill(
            icon: LucideIcons.badgeCheck,
            color: ZestTokens.statusHealthy,
            text: l10n.orchardDomainProven(at == null ? '' : DateFormat.yMMMd(l10n.localeName).format(at.toLocal())),
          )
        : _Pill(icon: LucideIcons.clock, color: ZestTokens.statusWarning, text: l10n.orchardDomainWaiting);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 14),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceSunken,
        border: Border.all(color: ZestTokens.borderSubtle),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(LucideIcons.globe, size: 15, color: ZestTokens.textSecondary),
              const SizedBox(width: 10),
              Expanded(
                child: Wrap(
                  spacing: 10,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(d.domain,
                        style: TextStyle(
                            fontFamily: 'JetBrainsMono',
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: ZestTokens.textPrimary)),
                    pill,
                  ],
                ),
              ),
              if (busy) const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.6)),
              TeamIconAction(
                key: ValueKey('domain-remove-${d.domain}'),
                icon: LucideIcons.trash2,
                tooltip: l10n.orchardDomainRemove,
                onPressed: busy ? null : onRemove,
              ),
            ],
          ),
          if (!d.verified && txt != null) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(l10n.orchardDomainPublishFor(d.domain),
                      style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textPrimary)),
                  const SizedBox(height: 8),
                  // TXT is the record's type in every language.
                  _RecordPart(label: l10n.orchardDomainRecordType, value: 'TXT'),
                  _RecordPart(label: l10n.orchardDomainRecordName, value: d.domain),
                  _RecordPart(
                    key: ValueKey('domain-txt-${d.domain}'),
                    label: l10n.orchardDomainRecordValue,
                    value: txt,
                    copied: l10n.orchardDomainCopied,
                    copyTip: l10n.orchardDomainCopy,
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      teamButton(
                        key: ValueKey('domain-check-${d.domain}'),
                        kind: TeamButtonKind.primary,
                        icon: LucideIcons.refreshCw,
                        label: l10n.orchardDomainCheck,
                        busy: busy,
                        onPressed: onCheck,
                      ),
                      if (checked != null)
                        Text(
                          l10n.orchardDomainLastChecked(timeAgoInSentence(l10n, checked.toLocal())),
                          key: ValueKey('domain-checked-${d.domain}'),
                          style: TextStyle(fontSize: 12, height: 1.45, color: ZestTokens.textSecondary),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A state in a few words, on a tint of its colour.
class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.color, required this.text});

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 5),
          Flexible(child: Text(text, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: color))),
        ],
      ),
    );
  }
}

/// One part of the record to publish: its name, its value in the code font,
/// and a button that copies the value.
class _RecordPart extends StatelessWidget {
  const _RecordPart({super.key, required this.label, required this.value, this.copied, this.copyTip});

  final String label;
  final String value;

  /// The copy button's name; "Copy" when null.
  final String? copyTip;

  /// What the notice says once copied; "Copied" when null.
  final String? copied;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(12, 2, 2, 2),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceRaised,
        border: Border.all(color: ZestTokens.borderSubtle),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(label, style: TextStyle(fontSize: 12, color: ZestTokens.textTertiary)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(value,
                style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12, color: ZestTokens.textPrimary)),
          ),
          SizedBox(
            width: teamOnPhone(context) ? 44 : 32,
            height: teamOnPhone(context) ? 44 : 32,
            child: IconButton(
              tooltip: copyTip ?? l10n.copy,
              padding: EdgeInsets.zero,
              icon: Icon(LucideIcons.copy, size: 14, color: ZestTokens.textSecondary),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: value));
                if (context.mounted) showTopSnackBar(context, copied ?? l10n.teamAdminValueCopied, isSuccess: true);
              },
            ),
          ),
        ],
      ),
    );
  }
}
