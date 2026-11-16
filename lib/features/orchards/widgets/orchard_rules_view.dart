import 'dart:convert';

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/rules/offline_pass.dart' show kOfflinePassMax;
import 'package:zestssh/features/orchards/rules/orchard_rules.dart';
import 'package:zestssh/features/orchards/team/team_notices.dart' show accessTimeText;
import 'package:zestssh/features/orchards/team/team_words.dart' show reauthChoiceNote, reauthSpanWords;
import 'package:zestssh/features/orchards/widgets/cert_handover_dialogs.dart' show showPassFromOwner, showSignHandedRequest;
import 'package:zestssh/features/orchards/widgets/member_devices_view.dart';
import 'package:zestssh/features/orchards/widgets/orchard_device_dialogs.dart';
import 'package:zestssh/features/orchards/widgets/outside_domains.dart';
import 'package:zestssh/features/orchards/widgets/orchard_step_up.dart';
import 'package:zestssh/features/orchards/widgets/team_export_view.dart';
import 'package:zestssh/features/orchards/widgets/team_recovery_view.dart';
import 'package:zestssh/features/orchards/widgets/team_tracking_view.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/cloud_reach_provider.dart';
import 'package:zestssh/features/orchards/widgets/team_admin_ui.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/edit_drafts.dart';
import 'package:zestssh/ui/widgets/zest_a11y.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';

// An Orchard's rules (3.0): what members need to join and to keep
// syncing. Owners set them, all at once, in one signed entry of the
// Orchard's record; everyone else sees them here. Each rule says who checks
// it: ZestSSH Cloud (two-step sign-in, address domains, signing in again)
// or each device (the app lock, no export, the offline limit).

/// The Rules screen of the Orchard [orchardId].
Future<void> showOrchardRules(BuildContext context, WidgetRef ref, String orchardId) {
  final l10n = AppLocalizations.of(context)!;
  return ZestDialogShell.showModal<void>(
    context,
    size: ZestModalSize.standard,
    tone: ZestDialogTone.info,
    icon: LucideIcons.scrollText,
    title: l10n.orchardRules,
    subtitle: l10n.orchardRulesSubtitle,
    body: OrchardRulesView(orchardId: orchardId),
    // Unsaved rules ask before the dialog goes (Close, Escape, the scrim).
    onDismissAttempt: mayLeaveOrchardRules,
    primaryAction: (
      label: l10n.close,
      onPressed: () async {
        if (await mayLeaveOrchardRules() && context.mounted) Navigator.of(context).pop();
      },
      icon: null,
    ),
  );
}

/// Rules changed on an Orchard's Rules page and not saved yet, with the
/// rules they were changed from. Kept while the page is away (another
/// page, another team), so leaving it loses nothing (two-step
/// sign-in was turned off with no reason given after leaving the
/// page without pressing Save, which sat mid-page).
final orchardRulesDraftProvider =
    StateProvider.family<({String base, RecordRules draft})?, String>((ref, orchardId) => null);

String _rulesKey(RecordRules r) => jsonEncode(r.toBody());

/// An address domain typed on an Orchard's Rules page and not added yet, by
/// the Orchard's id, kept while the page is away as the rules changed are
/// ([orchardRulesDraftProvider]). In memory only.
final orchardRulesTypedDomainProvider = editDraftsProvider<String>();

/// [orchard]'s unsaved rules in [entry]; null for none, or when the rules
/// changed underneath them since.
RecordRules? liveRulesDraft(({String base, RecordRules draft})? entry, OrchardSummary orchard) {
  if (entry == null || entry.base != _rulesKey(orchard.rules)) return null;
  return _rulesKey(entry.draft) == entry.base ? null : entry.draft;
}

/// How many of the rules (a row each, the auto-lock time on its own)
/// [draft] changes from [saved].
int ruleChanges(RecordRules saved, RecordRules draft) => [
      saved.require2fa != draft.require2fa,
      saved.requireSso != draft.requireSso,
      saved.ssoTwoStep != draft.ssoTwoStep,
      !setEquals(saved.emailDomains, draft.emailDomains),
      saved.reauthSeconds != draft.reauthSeconds,
      saved.trustedDevices != draft.trustedDevices,
      saved.requireAppLock != draft.requireAppLock,
      saved.maxLockMinutes != draft.maxLockMinutes,
      saved.noExport != draft.noExport,
      saved.offlineHours != draft.offlineHours,
      saved.screensSshOnly != draft.screensSshOnly,
      saved.screensLockRedirections != draft.screensLockRedirections,
    ].where((c) => c).length;

/// The unsaved changes to [orchard]'s rules in [entry], 0 for none (at
/// least 1 for any, where the same span was only written another way).
int unsavedRuleCount(({String base, RecordRules draft})? entry, OrchardSummary orchard) {
  final draft = liveRulesDraft(entry, orchard);
  if (draft == null) return 0;
  final n = ruleChanges(orchard.rules, draft);
  return n == 0 ? 1 : n;
}

/// The open Rules pages, the latest last: each asks before it goes while
/// its rules are changed and not saved.
final _leaveGuards = <Future<bool> Function()>[];

/// Whether the Rules page may go (the Team page's menu, a phone's back,
/// the dialog's Close): with unsaved rules it asks Save rules, Discard or
/// Keep editing first. True when it may.
Future<bool> mayLeaveOrchardRules() => _leaveGuards.isEmpty ? Future.value(true) : _leaveGuards.last();

class OrchardRulesView extends ConsumerStatefulWidget {
  const OrchardRulesView({
    super.key,
    required this.orchardId,
    this.onSaved,
    this.onOpenMembers,
    this.onOpenSignIn,
    this.scrollPadding,
    this.maxWidth,
    this.leading,
  });

  final String orchardId;

  /// Set where the view is a page: it scrolls itself with this padding,
  /// and the bar with Save rules stays under it, in sight, once anything
  /// changed. Null in a dialog, which scrolls it; Save is in its foot.
  final EdgeInsets? scrollPadding;

  /// How wide the page's rules and its bar go, with [scrollPadding].
  final double? maxWidth;

  /// Above the rules, in the page's scroll (a phone's line under the title).
  final Widget? leading;

  /// After a save. Null closes the dialog it sits in; the Team page stays.
  final VoidCallback? onSaved;

  /// Opens the Members page (to make a second owner for team recovery);
  /// null where there is none to open.
  final VoidCallback? onOpenMembers;

  /// Opens the Sign-in page (to turn company sign-in on before the rule
  /// that needs it); null where there is none to open.
  final VoidCallback? onOpenSignIn;

  @override
  ConsumerState<OrchardRulesView> createState() => _OrchardRulesViewState();
}

class _OrchardRulesViewState extends ConsumerState<OrchardRulesView> {
  /// Every how many hours, 0 for not required: below a day in hours,
  /// then whole days (kept in days, as older apps
  /// read them).
  // In hours: none, 1, 4 and 8 hours, 5, 30 and 90 days, then Custom (there
  // were thirteen before).
  static const reauthChoices = [0, 1, 4, 8, 120, 720, 2160];

  /// The Custom choice of [reauthChoices]' list.
  static const reauthCustom = -1;

  /// Minutes, 0 for any.
  static const lockChoices = [0, 1, 5, 10, 15, 30, 60, 240, 480, 1440];

  /// Hours, 0 for no limit.
  static const offlineChoices = [0, 24, 72, 168, 336, 720];

  /// The rules as saved, as [_rulesKey] writes them, from the last build.
  String? _base;
  final _domain = TextEditingController();
  String? _domainError;
  String? _error;
  bool _saving = false;

  /// Where a domain typed and not added is kept while the page is away.
  late final EditDrafts<String> _typed;

  @override
  void initState() {
    super.initState();
    _leaveGuards.add(_mayLeave);
    _typed = ref.read(orchardRulesTypedDomainProvider);
    _domain.text = _typed.take(widget.orchardId) ?? '';
  }

  @override
  void dispose() {
    _leaveGuards.remove(_mayLeave);
    if (_domain.text.trim().isNotEmpty) _typed.keep(widget.orchardId, _domain.text);
    _domain.dispose();
    super.dispose();
  }

  static String _key(RecordRules r) => _rulesKey(r);

  void _set(RecordRules next) {
    final base = _base;
    if (base == null) return;
    ref.read(orchardRulesDraftProvider(widget.orchardId).notifier).state =
        _key(next) == base ? null : (base: base, draft: next);
    setState(() => _error = null);
  }

  OrchardSummary? _orchardNow() =>
      ref.read(orchardSummariesProvider).valueOrNull?.where((o) => o.id == widget.orchardId).firstOrNull;

  /// Unsaved rules: Save rules, Discard or Keep editing. True when the page
  /// may go.
  Future<bool> _mayLeave() async {
    final orchard = _orchardNow();
    if (orchard == null || !orchard.isOwner || !mounted) return true;
    final entry = ref.read(orchardRulesDraftProvider(widget.orchardId));
    final draft = liveRulesDraft(entry, orchard);
    if (draft == null) return true;
    if (_saving) return false;
    final l10n = AppLocalizations.of(context)!;
    final choice = await ZestDialogShell.showModal<String>(
      context,
      size: ZestModalSize.compact,
      tone: ZestDialogTone.neutral,
      title: l10n.orchardRulesLeaveTitle,
      body: Text(l10n.orchardRulesLeaveBody(unsavedRuleCount(entry, orchard)),
          style: TextStyle(fontSize: 13, height: 1.45, color: ZestTokens.textSecondary)),
      primaryAction: (
        label: l10n.orchardRulesSave,
        onPressed: () => Navigator.of(context).pop('save'),
        icon: LucideIcons.check,
      ),
      secondaryAction: (label: l10n.zestCommonDiscard, onPressed: () => Navigator.of(context).pop('discard')),
      tertiaryAction: (label: l10n.orchardRulesKeepEditing, onPressed: () => Navigator.of(context).pop()),
    );
    if (!mounted) return false;
    switch (choice) {
      case 'save':
        return _save(orchard, draft, leaving: true);
      case 'discard':
        _discard();
        return true;
      default:
        return false;
    }
  }

  void _discard() {
    ref.read(orchardRulesDraftProvider(widget.orchardId).notifier).state = null;
    _domain.clear();
    setState(() {
      _error = null;
      _domainError = null;
    });
  }

  void _addDomain(RecordRules draft) {
    final l10n = AppLocalizations.of(context)!;
    final d = _domain.text.trim().toLowerCase();
    if (d.isEmpty) return;
    if (!isRuleDomain(d)) {
      setState(() => _domainError = l10n.orchardRulesDomainInvalid);
      return;
    }
    if (!draft.emailDomains.contains(d) && draft.emailDomains.length >= kMaxRuleDomains) {
      setState(() => _domainError = l10n.orchardRulesDomainLimit(kMaxRuleDomains));
      return;
    }
    _domain.clear();
    _domainError = null;
    _set(draft.copyWith(emailDomains: {...draft.emailDomains, d}));
  }

  /// Saves [draft]; [leaving] when the page goes after it (it neither
  /// closes nor calls onSaved then). True once saved.
  Future<bool> _save(OrchardSummary orchard, RecordRules draft, {bool leaving = false}) async {
    final l10n = AppLocalizations.of(context)!;
    // Their own address must be allowed, or they would hold themselves back.
    final mine = addressDomain(ref.read(currentUserProvider)?.email);
    if (draft.emailDomains.isNotEmpty && !draft.emailDomains.contains(mine)) {
      setState(() => _error = l10n.orchardRulesOwnDomain(mine.isEmpty ? '?' : mine));
      return false;
    }
    // Members a new list of domains leaves out stay in the team, held back
    // (nothing said so before saving). Who, what
    // happens, and what is to become of them, first: kept as guests, removed,
    // or not this list of domains at all.
    OutsideDecided? decided;
    OrchardPeople? people;
    if (draft.emailDomains.isNotEmpty && !setEquals(draft.emailDomains, orchard.rules.emailDomains)) {
      final service = ref.read(orchardServiceProvider);
      try {
        // Who they are as the server knows them: an address this device has
        // not heard yet is still held to the list.
        await service.refresh();
      } catch (e) {
        AppLogger.info('Orchard rules: the members were not read again for the domain check ($e)');
      }
      try {
        people = await service.people(orchard.id);
      } catch (e) {
        // The members could not be read here: the save itself says what
        // the server makes of it.
        AppLogger.warning('Orchard rules: members not read for the domain check ($e)');
      }
      if (!mounted) return false;
      final outside = people == null ? null : outsideDomainsOf(people, draft.emailDomains);
      if (outside != null && !outside.isEmpty) {
        final proven = await ref.read(orchardProvenDomainsProvider(orchard.id).future);
        if (!mounted) return false;
        final answer = await showOutsideDomains(context,
            domains: draft.emailDomains, outside: outside, beforeSaving: true, proven: {...proven});
        if (answer == null || !mounted) return false;
        if (answer is OutsideKeepDomains) {
          _set(draft.copyWith(emailDomains: {...orchard.rules.emailDomains}));
          return false;
        }
        decided = answer as OutsideDecided;
      }
    }
    // This device, measured against the new rules: allowed, with a word.
    final lock = await ref.read(deviceLockProvider.future);
    if (!mounted) return false;
    final unmet = deviceUnmet(draft, lockOn: lock.on, lockMinutes: lock.minutes);
    if (unmet.isNotEmpty) {
      final go = await ZestConfirmDialog.show(
        context,
        tone: ZestDialogTone.warning,
        title: l10n.orchardRulesThisDeviceTitle,
        // The team stops syncing here: the whole of it warns.
        body: '',
        warning: unmet.contains(UnmetRule.appLock)
            ? l10n.orchardRulesThisDeviceLock
            : l10n.orchardRulesThisDeviceTimeout(draft.maxLockMinutes),
        confirmLabel: l10n.orchardRulesSaveAnyway,
      );
      if (go != true || !mounted) return false;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final andMembers = decided;
    final summary = (
      what: l10n.stepUpRules,
      effects: andMembers == null ? const <String>[] : outsideEffects(andMembers, context, l10n),
    );
    try {
      final bool done;
      if (andMembers != null && andMembers.changesMembers) {
        done = await applyOutsideDomains(context, ref, orchard, andMembers, people: people!, rules: draft, summary: summary);
      } else {
        done = await withRecentSignIn(context, ref, () => ref.read(orchardServiceProvider).setRules(orchard.id, draft),
            summary: summary);
      }
      if (!done || !mounted) return false;
      ref.read(orchardRulesDraftProvider(widget.orchardId).notifier).state = null;
      ref.read(orchardListVersionProvider.notifier).state++;
      showTopSnackBar(context, l10n.orchardRulesSaved, isSuccess: true);
      if (leaving) return true;
      if (widget.onSaved != null) {
        widget.onSaved!();
      } else {
        Navigator.of(context).pop();
      }
      return true;
    } on OutsideSettleStopped catch (e) {
      // The rules went in first: they are saved, and the page reads everything
      // again, so this is said where it stays said.
      AppLogger.warning('Orchard rules: saved, and the members only in part ($e)');
      if (mounted) {
        ref.read(orchardRulesDraftProvider(widget.orchardId).notifier).state = null;
        showTopSnackBar(context, orchardChangeErrorMessage(e, l10n), isError: true, details: '$e');
      }
      return false;
    } catch (e) {
      AppLogger.warning('Orchard rules: not saved ($e)');
      if (mounted) setState(() => _error = orchardChangeErrorMessage(e, l10n));
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// "Custom..." for Sign in again: a number of hours or days, as the
  /// record takes them (up to 365 days or 8760 hours). Null when backed out.
  Future<int?> _customReauth(AppLocalizations l10n, int currentHours) async {
    final inDays = ValueNotifier<bool>(currentHours == 0 || currentHours % 24 == 0);
    final text = TextEditingController(
        text: currentHours == 0 ? '' : '${inDays.value ? currentHours ~/ 24 : currentHours}');
    final problem = ValueNotifier<String?>(null);
    int? hours() {
      final n = int.tryParse(text.text.trim());
      if (n == null || n < 1) return null;
      if (inDays.value) return n <= 365 ? n * 24 : null;
      return n <= 8760 ? n : null;
    }

    void done() {
      final h = hours();
      if (h == null) {
        problem.value = l10n.orchardRulesReauthCustomInvalid;
        return;
      }
      Navigator.of(context).pop(h);
    }

    final picked = await ZestDialogShell.showModal<int>(
      context,
      size: ZestModalSize.compact,
      tone: ZestDialogTone.info,
      title: l10n.orchardRulesReauthCustomTitle,
      onSubmit: done,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('rule-reauth-custom-number'),
                  controller: text,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  onSubmitted: (_) => done(),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 130,
                child: ValueListenableBuilder<bool>(
                valueListenable: inDays,
                builder: (_, days, _) => ZestSelect<bool>(
                  key: const ValueKey('rule-reauth-custom-unit'),
                  value: days,
                  onChanged: (v) => inDays.value = v,
                  items: [
                    ZestSelectItem(false, l10n.orchardRulesReauthUnitHours),
                    ZestSelectItem(true, l10n.orchardRulesReauthUnitDays),
                  ],
                ),
              ),
              ),
            ],
          ),
          ValueListenableBuilder<String?>(
            valueListenable: problem,
            builder: (_, p, _) => p == null ? const SizedBox.shrink() : TeamFieldNote(problem: p),
          ),
        ],
      ),
      primaryAction: (label: l10n.save, onPressed: done, icon: null),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
    );
    // Not disposed here: the dialog still draws them while it closes. They
    // go with it.
    return picked;
  }

  String _lockLabel(int minutes, AppLocalizations l10n) => minutes == 0
      ? l10n.orchardRulesLockAny
      : minutes % 60 == 0
          ? l10n.orchardRulesLockHours(minutes ~/ 60)
          : l10n.orchardRulesLockMinutes(minutes);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final orchard = ref
        .watch(orchardSummariesProvider)
        .valueOrNull
        ?.where((o) => o.id == widget.orchardId)
        .firstOrNull;
    if (orchard == null) return const SizedBox.shrink();
    // Starts from the rules as this device last read them, or the changes
    // not saved yet to those (none once they change underneath).
    final stored = _key(orchard.rules);
    _base = stored;
    final entry = ref.watch(orchardRulesDraftProvider(widget.orchardId));
    final draft = liveRulesDraft(entry, orchard) ?? orchard.rules;
    final saved = orchard.rules;
    // Leaving for another page from here asks first, as the menu does.
    VoidCallback? away(VoidCallback? open) => open == null
        ? null
        : () async {
            if (await _mayLeave()) open();
          };
    final canEdit = orchard.isOwner && !_saving;
    // How long a sign-in counts, in hours, as the dropdown shows it: the
    // shorter of the days and the hours that are set.
    final reauthNow = draft.reauthSeconds ~/ 3600;
    final changed = _key(draft) != stored;
    final asPage = widget.scrollPadding != null;

    // What ZestSSH Cloud checks when a member signs in or syncs.
    // Only owners can read how company sign-in is set up.
    final ssoActive = orchard.isOwner && (ref.watch(orchardSsoProvider(orchard.id)).valueOrNull?.active ?? false);
    final cloudRows = <Widget>[
      _RuleRow(
        key: const ValueKey('rule-two-step'),
        title: l10n.orchardRulesTwoStep,
        changed: draft.require2fa != saved.require2fa,
        body: l10n.orchardRulesTwoStepBody,
        trailing: ZestSwitch(value: draft.require2fa, onChanged: canEdit ? (v) => _set(draft.copyWith(require2fa: v)) : null),
        // No double second step, by an owner's choice, while company sign-in is
        // on, with what it costs in its words.
        sub: draft.require2fa && (ssoActive || draft.ssoTwoStep)
            ? _RuleRow(
                key: const ValueKey('rule-sso-two-step'),
                title: l10n.orchardRulesSsoTwoStep,
                changed: draft.ssoTwoStep != saved.ssoTwoStep,
                body: l10n.orchardRulesSsoTwoStepBody,
                trailing: ZestSwitch(
                  value: draft.ssoTwoStep,
                  onChanged: canEdit ? (v) => _set(draft.copyWith(ssoTwoStep: v)) : null,
                ),
              )
            : null,
      ),
      _SsoRule(
        orchard: orchard,
        on: draft.requireSso,
        onChanged: canEdit ? (v) => _set(draft.copyWith(requireSso: v)) : null,
        onOpenSignIn: away(widget.onOpenSignIn),
      ),
      _RuleRow(
        key: const ValueKey('rule-domains'),
        title: l10n.orchardRulesDomains,
        changed: !setEquals(draft.emailDomains, saved.emailDomains),
        body: l10n.orchardRulesDomainsBody,
        below: draft.emailDomains.isEmpty && !canEdit
            ? null
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (draft.emailDomains.isNotEmpty)
                    Padding(
                      padding: EdgeInsets.only(bottom: canEdit ? 8 : 0),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final d in draft.emailDomains.toList()..sort())
                            InputChip(
                              key: ValueKey('rule-domain-$d'),
                              label: Text(d, style: const TextStyle(fontSize: 12)),
                              visualDensity: VisualDensity.compact,
                              onDeleted: canEdit
                                  ? () => _set(draft.copyWith(emailDomains: {...draft.emailDomains}..remove(d)))
                                  : null,
                            ),
                        ],
                      ),
                    ),
                  if (canEdit) ...[
                    // The field at the button's height, Add beside it.
                    Row(
                      children: [
                        Expanded(
                          child: TeamField(
                            key: const ValueKey('rule-domain-field'),
                            controller: _domain,
                            hint: l10n.orchardRulesDomainHint,
                            wrong: _domainError != null,
                            keyboardType: TextInputType.url,
                            onSubmitted: (_) => _addDomain(draft),
                          ),
                        ),
                        const SizedBox(width: 8),
                        teamButton(
                          key: const ValueKey('rule-domain-add'),
                          icon: LucideIcons.plus,
                          label: l10n.orchardRulesDomainAdd,
                          onPressed: () => _addDomain(draft),
                        ),
                      ],
                    ),
                    TeamFieldNote(problem: _domainError),
                  ],
                ],
              ),
      ),
      _RuleRow(
        key: const ValueKey('rule-reauth'),
        title: l10n.orchardRulesReauth,
        changed: draft.reauthSeconds != saved.reauthSeconds,
        body: l10n.orchardRulesReauthBody,
        select: true,
        trailing: ZestSelect<int>(
          key: const ValueKey('rule-reauth-select'),
          value: reauthChoices.contains(reauthNow) ? reauthNow : null,
          hint: reauthSpanWords(l10n, reauthNow),
          onChanged: canEdit
              ? (picked) async {
                  final hours = picked == reauthCustom ? await _customReauth(l10n, reauthNow) : picked;
                  if (hours == null || !mounted) return;
                  _set(hours >= 24 && hours % 24 == 0
                      ? draft.copyWith(reauthDays: hours ~/ 24, reauthHours: 0)
                      : draft.copyWith(reauthDays: 0, reauthHours: hours));
                }
              : null,
          items: [
            for (final h in reauthChoices) ZestSelectItem(h, reauthSpanWords(l10n, h), note: reauthChoiceNote(l10n, h)),
            ZestSelectItem(reauthCustom, l10n.orchardRulesReauthCustom),
          ],
        ),
      ),
    ];
    // What each member's device checks for itself (approved devices are
    // held to by ZestSSH Cloud as well, which their words say).
    final deviceRows = <Widget>[
      _DevicesRule(
        orchard: orchard,
        on: draft.trustedDevices,
        saved: orchard.rules.trustedDevices,
        onChanged: canEdit ? (v) => _set(draft.copyWith(trustedDevices: v)) : null,
      ),
      _RuleRow(
        key: const ValueKey('rule-app-lock'),
        title: l10n.orchardRulesAppLock,
        changed: draft.requireAppLock != saved.requireAppLock,
        body: l10n.orchardRulesAppLockBody,
        trailing: ZestSwitch(
            value: draft.requireAppLock,
            onChanged: canEdit ? (v) => _set(draft.copyWith(requireAppLock: v, maxLockMinutes: v ? null : 0)) : null),
        // The longest auto-lock time: a choice of its own, on its own line,
        // its control in the same column as the switch above it.
        sub: _RuleRow(
          title: l10n.orchardRulesLockWithin,
          changed: draft.requireAppLock && draft.maxLockMinutes != saved.maxLockMinutes,
          select: true,
          trailing: ZestSelect<int>(
            key: const ValueKey('rule-lock-minutes'),
            value: lockChoices.contains(draft.maxLockMinutes) ? draft.maxLockMinutes : null,
            hint: _lockLabel(draft.maxLockMinutes, l10n),
            onChanged: canEdit && draft.requireAppLock ? (v) => _set(draft.copyWith(maxLockMinutes: v)) : null,
            items: [for (final m in lockChoices) ZestSelectItem(m, _lockLabel(m, l10n))],
          ),
          // What a time set here does (3.0).
          belowNote: draft.requireAppLock && draft.maxLockMinutes > 0 ? l10n.orchardRulesLockIdleNote : null,
        ),
      ),
      _RuleRow(
        key: const ValueKey('rule-no-export'),
        title: l10n.orchardRulesNoExport,
        changed: draft.noExport != saved.noExport,
        body: l10n.orchardRulesNoExportBody,
        trailing: ZestSwitch(value: draft.noExport, onChanged: canEdit ? (v) => _set(draft.copyWith(noExport: v)) : null),
      ),
      _RuleRow(
        key: const ValueKey('rule-offline'),
        title: l10n.orchardRulesOffline,
        changed: draft.offlineHours != saved.offlineHours,
        body: l10n.orchardRulesOfflineBody,
        select: true,
        // An outage of ZestSSH Cloud's own does not count towards the
        // limit, in a build that can have one proven to it (the status
        // service, lib/services/cloud/cloud_statement.dart). Said only
        // where it is so, and only once a limit is set. In a build that
        // cannot, the outage counts, and that is said instead, with the
        // way on.
        belowNote: draft.offlineHours <= 0
            ? null
            : ref.watch(cloudStatusConfigProvider).isSet
                ? l10n.orchardRulesOfflineOutageNote(kOutageExcuseMax.inDays)
                : l10n.orchardRulesOfflineOutageCounts(kOfflinePassMax.inDays),
        trailing: ZestSelect<int>(
          key: const ValueKey('rule-offline-select'),
          value: offlineChoices.contains(draft.offlineHours) ? draft.offlineHours : null,
          hint: l10n.orchardRulesOfflineHours(draft.offlineHours),
          onChanged: canEdit ? (v) => _set(draft.copyWith(offlineHours: v)) : null,
          items: [
            for (final h in offlineChoices)
              ZestSelectItem(h, h == 0 ? l10n.orchardRulesOfflineOff : l10n.orchardRulesOfflineDays(h ~/ 24)),
          ],
        ),
        // With a limit kept: a device that is, or will be, past it asks an
        // owner for an offline pass for all of the Orchard from here, and
        // an owner signs the request a member hands over.
        below: orchard.rules.offlineHours > 0 && orchard.active
            ? Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  // Open here by a pass an owner signed for all of it: until when.
                  if (orchard.passUntil case final until?)
                    Text(l10n.cratePassHolds(accessTimeText(until, l10n)),
                        key: const ValueKey('rule-offline-pass-holds'),
                        style: TextStyle(fontSize: 12.5, color: ZestTokens.textSecondary)),
                  teamButton(
                    key: const ValueKey('rule-offline-pass'),
                    icon: LucideIcons.qrCode,
                    label: l10n.passAskButton,
                    onPressed: () => showPassFromOwner(context, orchardId: orchard.id),
                  ),
                  if (orchard.isOwner)
                    teamButton(
                      key: const ValueKey('rule-offline-sign'),
                      icon: LucideIcons.fileSignature,
                      label: l10n.certSignButton,
                      onPressed: () => showSignHandedRequest(context),
                    ),
                ],
              )
            : null,
      ),
    ];

    // The team's remote screens (4.0): two rules each device holds itself to
    // when a screen connects (lib/features/screens/session/screen_team_rules.dart).
    final screenRows = <Widget>[
      _RuleRow(
        key: const ValueKey('rule-screens-ssh-only'),
        title: l10n.orchardRulesScreensSshOnly,
        changed: draft.screensSshOnly != saved.screensSshOnly,
        body: l10n.orchardRulesScreensSshOnlyBody,
        belowNote: draft.screensSshOnly ? l10n.orchardRulesScreensFromNextOpen : null,
        trailing: ZestSwitch(
            value: draft.screensSshOnly,
            onChanged: canEdit ? (v) => _set(draft.copyWith(screensSshOnly: v)) : null),
      ),
      _RuleRow(
        key: const ValueKey('rule-screens-no-sharing'),
        title: l10n.orchardRulesScreensNoSharing,
        changed: draft.screensLockRedirections != saved.screensLockRedirections,
        body: l10n.orchardRulesScreensNoSharingBody,
        belowNote: draft.screensLockRedirections ? l10n.orchardRulesScreensFromNextOpen : null,
        trailing: ZestSwitch(
            value: draft.screensLockRedirections,
            onChanged: canEdit ? (v) => _set(draft.copyWith(screensLockRedirections: v)) : null),
      ),
    ];

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.leading != null) ...[widget.leading!, const SizedBox(height: 14)],
        // The rules in two cards, by who checks them,
        // a row each split by hairlines.
        _RulesGroup(
          key: const ValueKey('rules-signing-in'),
          title: l10n.orchardRulesGroupSignIn,
          tagIcon: LucideIcons.cloud,
          tag: l10n.orchardRulesCheckedByCloud,
          rows: cloudRows,
        ),
        const SizedBox(height: 24),
        _RulesGroup(
          key: const ValueKey('rules-on-devices'),
          title: l10n.orchardRulesGroupDevices,
          tagIcon: LucideIcons.monitorSmartphone,
          tag: l10n.orchardRulesCheckedByDevice,
          rows: deviceRows,
        ),
        const SizedBox(height: 24),
        // Remote screens: the app's check on each device too (the server
        // cannot see a team's hosts).
        _RulesGroup(
          key: const ValueKey('rules-remote-screens'),
          title: l10n.settingsScreensSection,
          tagIcon: LucideIcons.monitorSmartphone,
          tag: l10n.orchardRulesCheckedByDevice,
          rows: screenRows,
        ),
        const SizedBox(height: 12),
        // The foot: what the rules are, and Save once something changed.
        Container(
          key: const ValueKey('rules-card'),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: ZestTokens.surfaceRaisedAlt,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: ZestTokens.borderSubtle),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_error != null && !asPage) ...[
                      Text(_error!,
                          key: const ValueKey('rules-error'),
                          style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.statusCritical)),
                      const SizedBox(height: 8),
                    ],
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            orchard.isOwner ? l10n.orchardRulesDeviceNote : l10n.orchardRulesOwnersOnly,
                            style: TextStyle(fontSize: 12, height: 1.45, color: ZestTokens.textSecondary),
                          ),
                        ),
                        if (orchard.isOwner && (changed || _saving) && !asPage) ...[
                          const SizedBox(width: 12),
                          teamButton(
                            key: const ValueKey('rules-save'),
                            kind: TeamButtonKind.primary,
                            icon: LucideIcons.check,
                            busy: _saving,
                            label: l10n.orchardRulesSave,
                            onPressed: () => _save(orchard, draft),
                          ),
                        ],
                      ],
                    ),
                    if (!orchard.isOwner) ...[
                      const SizedBox(height: 4),
                      Text(l10n.orchardRulesDeviceNote,
                          style: TextStyle(fontSize: 12, height: 1.45, color: ZestTokens.textTertiary)),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        // Team recovery: its own entry, turned on or off on its own.
        const SizedBox(height: 16),
        TeamRecoveryPanel(orchard: orchard, onAddOwner: away(widget.onOpenMembers)),
        // What the team records: its own entry too.
        const SizedBox(height: 16),
        TeamTrackingPanel(orchard: orchard),
        // And whether its events are sent on to a system of its own.
        const SizedBox(height: 16),
        TeamExportPanel(orchard: orchard),
      ],
    );
    if (!asPage) return content;
    final pad = widget.scrollPadding!;
    final unsaved = orchard.isOwner && (changed || _saving);
    Widget wide(Widget child) => Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(constraints: BoxConstraints(maxWidth: widget.maxWidth ?? double.infinity), child: child),
        );
    return PopScope(
      // A phone's back asks first too.
      canPop: !unsaved,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final nav = Navigator.of(context);
        if (await _mayLeave() && mounted) nav.pop();
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: SingleChildScrollView(padding: pad, child: wide(content))),
          // Under the page, in sight wherever it is scrolled to, once
          // anything changed: how much, Discard and Save rules (Save
          // sat mid-page and was missed before).
          if (unsaved)
            Container(
              key: const ValueKey('rules-unsaved-bar'),
              padding: EdgeInsets.fromLTRB(pad.left, 12, pad.right, 12),
              decoration: BoxDecoration(
                color: ZestTokens.surfaceRaisedAlt,
                border: Border(top: BorderSide(color: ZestTokens.borderSubtle)),
              ),
              child: wide(Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_error != null) ...[
                    Text(_error!,
                        key: const ValueKey('rules-error'),
                        style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.statusCritical)),
                    const SizedBox(height: 8),
                  ],
                  Row(
                    children: [
                      Icon(LucideIcons.circleDot, size: 15, color: ZestTokens.brandInk),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          l10n.orchardRulesUnsaved(unsavedRuleCount(entry, orchard)),
                          key: const ValueKey('rules-unsaved-count'),
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: ZestTokens.textPrimary),
                        ),
                      ),
                      const SizedBox(width: 12),
                      teamButton(
                        key: const ValueKey('rules-discard'),
                        label: l10n.zestCommonDiscard,
                        onPressed: _saving ? null : _discard,
                      ),
                      const SizedBox(width: 8),
                      teamButton(
                        key: const ValueKey('rules-save'),
                        kind: TeamButtonKind.primary,
                        icon: LucideIcons.check,
                        busy: _saving,
                        label: l10n.orchardRulesSave,
                        onPressed: () => _save(orchard, draft),
                      ),
                    ],
                  ),
                ],
              )),
            ),
        ],
      ),
    );
  }
}

/// One rule: what it is and who checks it, and its control in a column of
/// its own at the end (200 wide for a choice, so the controls line up), or
/// under the words on a phone. [below] goes under the words, [sub] is a
/// choice that belongs to the rule (on a line of its own under it).
class _RuleRow extends StatelessWidget {
  const _RuleRow({
    super.key,
    required this.title,
    this.body,
    this.trailing,
    this.select = false,
    this.below,
    this.belowNote,
    this.belowNoteWidget,
    this.sub,
    this.changed = false,
  });

  final String title;

  /// Changed and not saved yet: said beside the title.
  final bool changed;
  final String? body;
  final Widget? trailing;

  /// [trailing] is a choice (a select), drawn 200 wide.
  final bool select;
  final Widget? below;

  /// A line under [below] saying what the choice there does.
  final String? belowNote;

  /// In place of [belowNote], where it says more than a line.
  final Widget? belowNoteWidget;
  final _RuleRow? sub;

  static const controlWidth = 200.0;

  @override
  Widget build(BuildContext context) {
    // Its switch or choice is said with the rule's name to a screen reader
    // ("Require two-step sign-in, switch, off"; it was a switch of nothing).
    final trailing = this.trailing == null ? null : ZestControlLabel(label: title, child: this.trailing!);
    return LayoutBuilder(builder: (context, box) {
      final narrow = box.maxWidth < kTeamNarrow;
      final selectUnder = narrow && select;
      final words = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text.rich(
            TextSpan(text: title, children: [
              if (changed)
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Padding(
                    padding: const EdgeInsetsDirectional.only(start: 8),
                    child: Container(
                      key: const ValueKey('rule-not-saved'),
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: ZestTokens.brandSubtle,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(AppLocalizations.of(context)!.orchardRulesNotSaved,
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, height: 1.3, color: zestBrandOnSubtle)),
                    ),
                  ),
                ),
            ]),
            style: TextStyle(
                fontSize: sub == null && body == null ? 13 : 14,
                fontWeight: body == null ? FontWeight.w500 : FontWeight.w600,
                height: 1.4,
                color: ZestTokens.textPrimary),
          ),
          if (body != null) ...[
            const SizedBox(height: 2),
            Text(body!, style: TextStyle(fontSize: 13, height: 1.45, color: ZestTokens.textSecondary)),
          ],
          if (selectUnder && trailing != null) ...[const SizedBox(height: 10), trailing],
          if (below != null) ...[const SizedBox(height: 10), below!],
          if (belowNoteWidget != null) ...[const SizedBox(height: 10), belowNoteWidget!],
          if (belowNote != null) ...[
            const SizedBox(height: 6),
            Text(belowNote!, style: TextStyle(fontSize: 12, height: 1.45, color: ZestTokens.textSecondary)),
          ],
        ],
      );
      // A choice that belongs to a rule (no words of its own) sits on a
      // line of its own, its control centred beside its name.
      final inset = body == null && sub == null;
      final row = Row(
        crossAxisAlignment: inset ? CrossAxisAlignment.center : CrossAxisAlignment.start,
        children: [
          Expanded(child: words),
          if (trailing != null && !selectUnder) ...[
            const SizedBox(width: 16),
            SizedBox(
              width: select ? controlWidth : null,
              child: Align(alignment: AlignmentDirectional.topEnd, child: trailing),
            ),
          ],
        ],
      );
      if (inset) {
        // Set in, on a tint of its own inside its rule's padding.
        return Container(
          margin: const EdgeInsets.only(top: 12),
          padding: EdgeInsets.fromLTRB(narrow ? 12 : 14, 8, 8, 8),
          decoration: BoxDecoration(
            color: ZestTokens.surfaceRaisedAlt,
            borderRadius: BorderRadius.circular(8),
          ),
          child: row,
        );
      }
      return ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 60),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: narrow ? 16 : 20, vertical: 16),
          child: sub == null
              ? row
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [row, sub!]),
        ),
      );
    });
  }
}

/// "Approved devices only": members get in only from devices the team
/// approved. An owner turns it on once this device and one more device of
/// an owner are approved, so that losing one device does not lock the
/// owners out of their own Orchard; until then the switch is locked and the
/// row says what is missing, and does it where it can. Turning it off is
/// always possible.
class _DevicesRule extends ConsumerWidget {
  const _DevicesRule({required this.orchard, required this.on, required this.saved, required this.onChanged});

  final OrchardSummary orchard;

  /// As the page has it now, and as the record has it.
  final bool on;
  final bool saved;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final standing = ref.watch(deviceStandingProvider(orchard.id)).valueOrNull;
    final ready = standing?.canTurnOn ?? false;
    final change = onChanged;
    Widget? below;
    var locked = false;
    if (orchard.isOwner && standing != null && !saved) {
      if (!ready) {
        locked = !on;
        final (text, action) = !standing.approved
            ? standing.canApproveItself
                ? (
                    l10n.orchardRulesDevicesNeedThis,
                    (label: l10n.deviceApproveThis, onPressed: () => approveThisDevice(context, ref, orchard.id)),
                  )
                : (
                    l10n.orchardRulesDevicesNeedAsk,
                    (label: l10n.deviceAskAction, onPressed: () => showDeviceAsk(context, ref, orchard)),
                  )
            : (l10n.orchardRulesDevicesNeedSecond, null);
        below = _LockedLine(
          key: const ValueKey('rule-devices-needs'),
          text: text,
          action: action == null
              ? null
              : _SmallButton(
                  key: const ValueKey('rule-devices-action'),
                  icon: LucideIcons.shieldCheck,
                  label: action.label,
                  onPressed: action.onPressed,
                ),
        );
      } else if (standing.without.isNotEmpty) {
        // Who will be held back: amber, short, with its sign.
        below = Row(
          key: const ValueKey('rule-devices-without'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(LucideIcons.alertTriangle, size: 14, color: ZestTokens.statusWarning),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(l10n.orchardRulesDevicesWithout(standing.without.length),
                  style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.statusWarning)),
            ),
          ],
        );
      }
    }
    final toggle = ZestSwitch(
        key: const ValueKey('rule-devices-switch'), value: on, onChanged: change == null || (!on && !ready) ? null : change);
    return _RuleRow(
      changed: on != saved,
      key: const ValueKey('rule-devices'),
      title: l10n.orchardRulesDevices,
      body: l10n.orchardRulesDevicesBody,
      trailing: locked ? _LockedSwitch(toggle: toggle) : toggle,
      below: below,
      // What cannot be undone by anyone, said before it is turned on: a line
      // of help with its sign, under the amber one.
      belowNoteWidget: orchard.isOwner && on && !saved
          ? _NoteLine(icon: LucideIcons.info, text: l10n.orchardRulesDevicesLossNote)
          : null,
    );
  }
}

/// A line of help with its sign before it.
class _NoteLine extends StatelessWidget {
  const _NoteLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: 14, color: ZestTokens.textTertiary),
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: TextStyle(fontSize: 12, height: 1.45, color: ZestTokens.textSecondary))),
      ],
    );
  }
}

/// A group of rules: its name, a tag that says who checks them, and the
/// rules in one card, split by hairlines.
class _RulesGroup extends StatelessWidget {
  const _RulesGroup({super.key, required this.title, required this.tagIcon, required this.tag, required this.rows});

  final String title;
  final IconData tagIcon;
  final String tag;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(title,
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, height: 1.3, color: ZestTokens.textPrimary)),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: ZestTokens.surfaceRaisedAlt,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: ZestTokens.borderSubtle),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(tagIcon, size: 12, color: ZestTokens.textSecondary),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(tag,
                        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500, color: ZestTokens.textSecondary)),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: ZestTokens.surfaceRaised,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: ZestTokens.borderSubtle),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0) Divider(height: 1, thickness: 1, color: ZestTokens.borderSubtle),
                rows[i],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// A switch that cannot move yet: a lock before it says so.
class _LockedSwitch extends StatelessWidget {
  const _LockedSwitch({required this.toggle});

  final Widget toggle;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(LucideIcons.lock, size: 14, color: ZestTokens.textTertiary),
        const SizedBox(width: 8),
        toggle,
      ],
    );
  }
}

/// What a locked rule waits for: a lock, the words, and the one thing that
/// unlocks it beside them where there is room (under them on a phone).
class _LockedLine extends StatelessWidget {
  const _LockedLine({super.key, required this.text, this.action});

  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final words = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(LucideIcons.lock, size: 13, color: ZestTokens.textTertiary),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(text, style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textSecondary)),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [words, ?action],
      ),
    );
  }
}

/// A small outlined button inside a rule's row.
class _SmallButton extends StatelessWidget {
  const _SmallButton({super.key, required this.icon, required this.label, required this.onPressed});

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        // The theme's height: 32 at least to a mouse (compact made it 26).
        visualDensity: VisualDensity.standard,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 12.5, fontWeight: FontWeight.w600),
      ),
      icon: Icon(icon, size: 14),
      label: Text(label),
    );
  }
}

/// A link to another page, in the accent's ink with its chevron.
class _LinkAction extends StatelessWidget {
  const _LinkAction({super.key, required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return teamButton(icon: LucideIcons.chevronRight, label: label, onPressed: onPressed);
  }
}

/// "Company sign-in required": members sign in through the Orchard's
/// company sign-in. An owner turns it on only once the company sign-in is
/// on (the Sign-in page): until then the switch is locked and the row says
/// so, with the way there. Turning it off is always possible.
class _SsoRule extends ConsumerWidget {
  const _SsoRule({required this.orchard, required this.on, required this.onChanged, this.onOpenSignIn});

  final OrchardSummary orchard;
  final bool on;
  final ValueChanged<bool>? onChanged;

  /// Opens the Sign-in page, where company sign-in is turned on; null where
  /// there is none to open.
  final VoidCallback? onOpenSignIn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    // Only owners can read how company sign-in is set up.
    final active = orchard.isOwner &&
        (ref.watch(orchardSsoProvider(orchard.id)).valueOrNull?.active ?? false);
    final change = onChanged;
    final locked = orchard.isOwner && !on && !active;
    final toggle = ZestSwitch(key: const ValueKey('rule-sso-switch'), value: on, onChanged: change == null || (!on && !active) ? null : change);
    return _RuleRow(
      changed: on != orchard.rules.requireSso,
      key: const ValueKey('rule-sso'),
      title: l10n.orchardRulesRequireSso,
      body: l10n.orchardRulesRequireSsoBody,
      // Locked until company sign-in is on: the lock says why it does not
      // move, the way to the page that turns it on under the words.
      trailing: locked ? _LockedSwitch(toggle: toggle) : toggle,
      // Why it can never lock the team out.
      belowNote: orchard.isOwner && !locked ? l10n.orchardRulesRequireSsoOwners : null,
      below: locked
          ? _LockedLine(
              key: const ValueKey('rule-sso-off'),
              text: l10n.orchardRulesRequireSsoOff,
              action: onOpenSignIn == null
                  ? null
                  : _LinkAction(
                      key: const ValueKey('rule-sso-open-sign-in'),
                      label: l10n.teamAdminOpenSignIn,
                      onPressed: onOpenSignIn!,
                    ),
            )
          : null,
    );
  }
}
