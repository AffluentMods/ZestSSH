import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/directory/directory_roles.dart';
import 'package:zestssh/features/orchards/directory/orchard_directory_api.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/widgets/orchard_step_up.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/features/orchards/widgets/team_admin_ui.dart' show teamButton, TeamButtonKind;
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/settings_providers.dart' show recordingModeProvider;
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';
import 'package:zestssh/utils/secret_clipboard.dart';
import 'package:zestssh/l10n/time_text.dart';

// Directory sync for an Orchard (3.0), on the Team page's
// Sign-in page. The company's directory (Okta, Entra ID and others, over
// SCIM 2.0) tells ZestSSH Cloud who joins, who leaves and which groups they
// are in. Only taking access away happens by itself: the server holds back
// a removed or lowered member at once. Every grant (inviting someone, a
// higher role) waits for an owner or admin here, who acts on it with the
// Orchard's usual signed changes, checked against the signed record first.

/// What went wrong with directory sync, in words a person can act on.
String directoryErrorMessage(Object error, AppLocalizations l10n) {
  if (error is OrchardServerException) {
    switch (error.code) {
      case 'domain-required':
        return l10n.directoryNeedsDomain;
      case 'directory-on':
      case 'directory-off':
        return l10n.orchardErrorChanged;
    }
  }
  return orchardChangeErrorMessage(error, l10n);
}

/// Whether [change] still needs doing, as the signed [record] stands: a
/// member already removed, already in that role, or an address already in
/// the Orchard needs nothing more, and such a change is set aside.
bool directoryChangeStillNeeded(DirectoryChange change, OrchardRecord record, {Set<String> invited = const {}}) {
  final member = change.uid == null ? null : record.members[change.uid];
  final active = member != null && member.status == MemberStatus.active;
  return switch (change.kind) {
    DirectoryChangeKind.remove => member != null && member.status != MemberStatus.removed,
    DirectoryChangeKind.raise || DirectoryChangeKind.lower => active && change.role != null && member.role != change.role,
    DirectoryChangeKind.add => change.role != null && !invited.contains(change.email.toLowerCase()),
  };
}

/// The directory's changes on their own, for an owner or admin (from the
/// Team page's Overview).
Future<void> showOrchardDirectoryQueue(BuildContext context, WidgetRef ref, OrchardSummary orchard) async {
  final l10n = AppLocalizations.of(context)!;
  await ZestDialogShell.showModal<void>(
    context,
    size: ZestModalSize.standard,
    tone: ZestDialogTone.info,
    icon: LucideIcons.building2,
    title: l10n.directoryChanges,
    body: OrchardDirectoryView(orchard: orchard, queueOnly: true),
    primaryAction: (label: l10n.close, onPressed: () => Navigator.of(context).pop(), icon: null),
  );
  ref.invalidate(orchardDirectoryProvider(directoryReaderOf(orchard)));
}

class OrchardDirectoryView extends ConsumerStatefulWidget {
  const OrchardDirectoryView({super.key, required this.orchard, this.queueOnly = false, this.intro = true});

  final OrchardSummary orchard;

  /// Whether it says first what directory sync is (the Sign-in page's step
  /// says it above).
  final bool intro;

  /// Only the changes waiting, nothing about running the directory.
  final bool queueOnly;

  @override
  ConsumerState<OrchardDirectoryView> createState() => _OrchardDirectoryViewState();
}

class _OrchardDirectoryViewState extends ConsumerState<OrchardDirectoryView> {
  OrchardDirectory? _directory;

  /// The Orchard's people and roles as the signed record on this device has
  /// them, brought up to date first.
  OrchardPeople? _people;

  /// Groups opened to show their people, and who is in each, as read.
  final _open = <String>{};
  final _groupPeople = <String, Future<List<DirectoryPerson>>>{};

  /// What is running: 'on', 'off', 'token', a group id, or 'change-' and the change's id.
  String? _busy;
  String? _error;

  String get _orchardId => widget.orchard.id;
  OrchardDirectoryApi get _api => ref.read(orchardDirectoryApiProvider);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final service = ref.read(orchardServiceProvider);
      final directory = await _api.get(_orchardId);
      await service.refresh();
      final people = await service.people(_orchardId);
      // Changes the signed record already reflects are set aside: nothing
      // is left to do about them.
      final invited = {
        if (directory.pending.any((c) => c.kind == DirectoryChangeKind.add))
          for (final i in await service.invites(_orchardId)) i.email.toLowerCase(),
        for (final m in people.members)
          if (m.email != null) m.email!.toLowerCase(),
      };
      final done = [
        for (final c in directory.pending)
          if (!directoryChangeStillNeeded(c, people.record, invited: invited)) c,
      ];
      for (final c in done) {
        await _api.dismiss(_orchardId, c.id);
      }
      if (!mounted) return;
      setState(() {
        _people = people;
        _directory = done.isEmpty
            ? directory
            : OrchardDirectory(
                enabled: directory.enabled,
                scimUrl: directory.scimUrl,
                lastContact: directory.lastContact,
                lowers: directory.lowers,
                autoRoles: directory.autoRoles,
                groups: directory.groups,
                pending: [
                  for (final c in directory.pending)
                    if (!done.contains(c)) c,
                ],
                held: directory.held,
              );
      });
    } catch (e) {
      AppLogger.warning('Directory sync: could not be read ($e)');
      if (mounted) setState(() => _error = directoryErrorMessage(e, AppLocalizations.of(context)!));
    }
  }

  Future<void> _run(String key, Future<void> Function() action) async {
    setState(() {
      _busy = key;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      AppLogger.warning('Directory sync: $key did not happen ($e)');
      if (mounted) setState(() => _error = directoryErrorMessage(e, AppLocalizations.of(context)!));
    } finally {
      if (mounted) setState(() => _busy = null);
      await _load();
    }
  }

  Future<void> _turnOn() async {
    final l10n = AppLocalizations.of(context)!;
    DirectoryToken? token;
    await _run('on', () async {
      await withRecentSignIn(context, ref, () async => token = await _api.enable(_orchardId),
          summary: (what: l10n.stepUpDirectoryOn, effects: const []));
    });
    final shown = token;
    if (shown != null && mounted) await _showToken(shown);
  }

  Future<void> _newToken() async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.warning,
      title: l10n.directoryNewTokenTitle,
      // That the old token stops at once is what warns, the whole of it.
      body: '',
      warning: l10n.directoryNewTokenBody,
      confirmLabel: l10n.directoryNewToken,
    );
    if (ok != true || !mounted) return;
    DirectoryToken? token;
    await _run('token', () async {
      await withRecentSignIn(context, ref, () async => token = await _api.newToken(_orchardId),
          summary: (what: l10n.stepUpDirectoryToken, effects: const []));
    });
    final shown = token;
    if (shown != null && mounted) await _showToken(shown);
  }

  Future<void> _turnOff() async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.directoryOffTitle,
      body: l10n.directoryOffBody,
      confirmLabel: l10n.directoryTurnOff,
    );
    if (ok != true || !mounted) return;
    await _run('off', () async {
      if (await withRecentSignIn(context, ref, () => _api.disable(_orchardId),
              summary: (what: l10n.stepUpDirectoryOff, effects: const [])) &&
          mounted) {
        showTopSnackBar(context, l10n.directoryTurnedOff, isSuccess: true);
      }
    });
  }

  /// The token, this once, with where the directory sends to.
  Future<void> _showToken(DirectoryToken token) {
    final l10n = AppLocalizations.of(context)!;
    return ZestDialogShell.showModal<void>(
      context,
      size: ZestModalSize.standard,
      tone: ZestDialogTone.warning,
      icon: LucideIcons.keyRound,
      title: l10n.directoryTokenTitle,
      subtitle: l10n.directoryTokenLead,
      barrierDismissible: false,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CopyRow(key: const ValueKey('directory-url'), label: l10n.directoryScimUrl, value: token.scimUrl),
          const SizedBox(height: 10),
          _CopyRow(key: const ValueKey('directory-token'), label: l10n.directoryToken, value: token.token, secret: true),
          const SizedBox(height: 12),
          // Shown only this once: the one sentence that warns.
          ZestCallout(l10n.directoryTokenOnce),
        ],
      ),
      primaryAction: (label: l10n.directoryTokenSaved, onPressed: () => Navigator.of(context).pop(), icon: null),
    );
  }

  Future<void> _mapGroup(DirectoryGroup group, String? role) async {
    final l10n = AppLocalizations.of(context)!;
    await _run(group.id, () async {
      await withRecentSignIn(context, ref, () => _api.mapGroup(_orchardId, group.id, role),
          summary: (what: l10n.stepUpDirectoryGroup(group.name), effects: const []));
    });
  }

  Future<void> _setLowers(bool lowers) async {
    final l10n = AppLocalizations.of(context)!;
    await _run('lowers', () async {
      await withRecentSignIn(context, ref, () => _api.setLowers(_orchardId, lowers),
          summary: (what: lowers ? l10n.stepUpDirectoryLowersOn : l10n.stepUpDirectoryLowersOff, effects: const []));
    });
  }

  Future<void> _setAutoRoles(bool on) async {
    final l10n = AppLocalizations.of(context)!;
    var made = 0;
    await _run('auto-roles', () async {
      await withRecentSignIn(context, ref, () async {
        await _api.setAutoRoles(_orchardId, on);
        // Turned on here, this device makes the roles at once.
        if (on) made = await _makeRoles();
      }, summary: (what: on ? l10n.stepUpDirectoryAutoRolesOn : l10n.stepUpDirectoryAutoRolesOff, effects: const []));
    });
    if (made > 0 && mounted) showTopSnackBar(context, l10n.directoryAutoRolesMade(made), isSuccess: true);
  }

  /// The roles the waiting groups need, made on this device now.
  Future<int> _makeRoles() async {
    final service = ref.read(orchardServiceProvider);
    final directory = await _api.get(_orchardId);
    final done = await makeDirectoryRoles(service, _api, _orchardId, directory);
    if (done.made + done.renamed > 0) ref.read(orchardListVersionProvider.notifier).state++;
    return done.made;
  }

  Future<void> _makeRolesNow() async {
    final l10n = AppLocalizations.of(context)!;
    var made = 0;
    await _run('auto-roles', () async {
      await withRecentSignIn(context, ref, () async => made = await _makeRoles(),
          summary: (what: l10n.stepUpDirectoryAutoRolesOn, effects: const []));
    });
    if (made > 0 && mounted) showTopSnackBar(context, l10n.directoryAutoRolesMade(made), isSuccess: true);
  }

  /// Acts on [change] with the Orchard's usual signed change, then sets it
  /// aside. A change that takes access away is followed by new keys for
  /// what it left waiting, as far as this account may replace them.
  Future<void> _act(DirectoryChange change) async {
    final l10n = AppLocalizations.of(context)!;
    if (_people == null) return;
    final service = ref.read(orchardServiceProvider);
    final role = change.role;
    final name = change.email;
    final ({String title, String body, String confirm, ZestDialogTone tone}) ask = switch (change.kind) {
      DirectoryChangeKind.add => (
          title: l10n.directoryInviteTitle(name),
          body: l10n.directoryInviteBody(_roleLabel(role, l10n)),
          confirm: l10n.directoryInvite,
          tone: ZestDialogTone.info,
        ),
      DirectoryChangeKind.raise || DirectoryChangeKind.lower => (
          title: l10n.directoryRoleTitle(name),
          body: l10n.directoryRoleBody(_roleLabel(role, l10n)),
          confirm: l10n.directoryChangeRole,
          tone: ZestDialogTone.info,
        ),
      DirectoryChangeKind.remove => (
          title: l10n.orchardRemoveTitle(name),
          body: l10n.orchardRemoveBody,
          confirm: l10n.orchardRemoveConfirm,
          tone: ZestDialogTone.destructive,
        ),
    };
    final ok = await ZestConfirmDialog.show(context, tone: ask.tone, title: ask.title, body: ask.body, confirmLabel: ask.confirm);
    if (ok != true || !mounted) return;
    await _run('change-${change.id}', () async {
      final revokes = change.kind != DirectoryChangeKind.add;
      final done = await withRecentSignIn(
        context,
        ref,
        () => switch (change.kind) {
          DirectoryChangeKind.add => service.invite(_orchardId, email: change.email, role: role!).then((_) {}),
          DirectoryChangeKind.raise ||
          DirectoryChangeKind.lower =>
            service.setMemberRole(_orchardId, change.uid!, role!),
          DirectoryChangeKind.remove => service.removeMember(_orchardId, change.uid!),
        },
        summary: (what: ask.title, effects: [if (revokes) l10n.stepUpEffectKeysIfLost]),
      );
      if (!done) return;
      var left = const <String>[];
      if (revokes && await service.keysWaiting(_orchardId)) left = await service.rotateDue(_orchardId);
      await _api.dismiss(_orchardId, change.id);
      ref.read(orchardListVersionProvider.notifier).state++;
      if (!mounted) return;
      showTopSnackBar(context, l10n.directoryChangeDone, isSuccess: true);
      if (left.isNotEmpty) showTopSnackBar(context, l10n.orchardKeysReplaceLater, isWarning: true);
    });
  }

  /// Every invitation waiting under Directory changes, at once, after
  /// saying how many seats it takes.
  /// Where the seats run short, those that fit go first and
  /// the rest stay waiting.
  Future<void> _inviteAll(List<DirectoryChange> adds) async {
    final l10n = AppLocalizations.of(context)!;
    if (adds.isEmpty) return;
    final free = ref.read(orchardBillingProvider(_orchardId)).valueOrNull?.seats.free;
    final fit = free == null ? adds.length : free.clamp(0, adds.length);
    final ok = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.info,
      title: l10n.directoryInviteAllTitle(fit),
      body: fit < adds.length
          ? l10n.directoryInviteAllShort(fit, adds.length)
          : free == null
              ? l10n.directoryInviteAllSeats
              : l10n.directoryInviteAllBody(fit, free),
      confirmLabel: l10n.directoryInviteAll(fit),
    );
    if (ok != true || !mounted || fit == 0) return;
    final service = ref.read(orchardServiceProvider);
    var done = 0;
    await _run('invite-all', () async {
      await withRecentSignIn(context, ref, () async {
        for (final c in adds.take(fit)) {
          await service.invite(_orchardId, email: c.email, role: c.role!);
          await _api.dismiss(_orchardId, c.id);
          done++;
        }
      }, summary: (what: l10n.directoryInviteAllTitle(fit), effects: const []));
      ref.read(orchardListVersionProvider.notifier).state++;
      if (mounted && done > 0) showTopSnackBar(context, l10n.directoryInvitedAll(done), isSuccess: true);
    });
  }

  /// Every waiting change set aside without doing it.
  Future<void> _setAsideAll(List<DirectoryChange> changes) => _run('set-aside-all', () async {
        for (final c in changes) {
          await _api.dismiss(_orchardId, c.id);
        }
      });

  Future<void> _setAside(DirectoryChange change) =>
      _run('change-${change.id}', () => _api.dismiss(_orchardId, change.id));

  String _roleLabel(String? role, AppLocalizations l10n) {
    if (role == null) return l10n.directoryNoRole;
    final names = {for (final r in _people?.roles ?? const <OrchardRoleView>[]) r.id: r.name};
    return orchardRoleLabel(role, l10n, names: names);
  }

  Widget _changeRow(DirectoryChange c, AppLocalizations l10n, bool idle) => _ChangeRow(
        key: ValueKey('directory-change-${c.id}'),
        text: switch (c.kind) {
          DirectoryChangeKind.add => l10n.directoryChangeAdd(c.email, _roleLabel(c.role, l10n)),
          DirectoryChangeKind.raise => l10n.directoryChangeRaise(c.email, _roleLabel(c.role, l10n)),
          DirectoryChangeKind.lower => l10n.directoryChangeLower(c.email, _roleLabel(c.role, l10n)),
          DirectoryChangeKind.remove => l10n.directoryChangeRemove(c.email),
        },
        busy: _busy == 'change-${c.id}',
        onAct: idle && (c.kind == DirectoryChangeKind.remove || c.role != null) ? () => _act(c) : null,
        actLabel: switch (c.kind) {
          DirectoryChangeKind.add => l10n.directoryInvite,
          DirectoryChangeKind.raise || DirectoryChangeKind.lower => l10n.directoryChangeRole,
          DirectoryChangeKind.remove => l10n.orchardRemoveConfirm,
        },
        onSetAside: idle ? () => _setAside(c) : null,
      );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final directory = _directory;
    if (directory == null) {
      return _error == null
          ? const Padding(
              padding: EdgeInsets.all(12),
              child: Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 1.6))),
            )
          : _ErrorLine(_error!);
    }
    final idle = _busy == null;
    final isOwner = widget.orchard.isOwner;
    if (widget.queueOnly) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (directory.pending.isEmpty)
            Text(l10n.directoryChangesEmpty, style: TextStyle(fontSize: 12, color: AppColors.v3TextSecondary))
          else
            for (final c in directory.pending) _changeRow(c, l10n, idle),
          if (_error != null) ...[const SizedBox(height: 8), _ErrorLine(_error!)],
        ],
      );
    }
    final roles = <String?>[
      null,
      FixedRoles.admin,
      for (final r in _people?.roles ?? const <OrchardRoleView>[]) r.id,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.intro) ...[
          Text(l10n.directoryIntro, style: TextStyle(fontSize: 12.5, height: 1.45, color: AppColors.v3TextSecondary)),
          const SizedBox(height: 10),
        ],
        if (!directory.enabled) ...[
          if (isOwner)
            Align(
              alignment: Alignment.centerLeft,
              child: ZestButton(
                key: const ValueKey('directory-on'),
                label: l10n.directoryTurnOn,
                icon: LucideIcons.power,
                variant: ZestButtonVariant.primary,
                isLoading: _busy == 'on',
                onPressed: idle ? _turnOn : null,
              ),
            ),
        ] else ...[
          _Line(
            icon: LucideIcons.badgeCheck,
            color: AppColors.v3Success,
            text: directory.lastContact == null
                ? l10n.directoryOnNoContact
                : l10n.directoryOnLastContact(
                    DateFormat.yMMMd(l10n.localeName).add_jm().formatPlain(directory.lastContact!.toLocal())),
          ),
          if (directory.scimUrl != null) ...[
            const SizedBox(height: 8),
            _CopyRow(label: l10n.directoryScimUrl, value: directory.scimUrl!),
            // The token was shown once: it is there, and never shown again
            // (it looked gone before).
            const SizedBox(height: 8),
            Column(
              key: const ValueKey('directory-token-hidden'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.directoryToken, style: TextStyle(fontSize: 11.5, color: AppColors.v3TextTertiary)),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Text('\u2022' * 16,
                        style: TextStyle(fontSize: 13, fontFamily: 'JetBrainsMono', color: AppColors.v3TextSecondary)),
                    const SizedBox(width: 8),
                    Icon(LucideIcons.lock, size: 12, color: AppColors.v3TextTertiary),
                  ],
                ),
                const SizedBox(height: 2),
                Text(l10n.directoryTokenHidden,
                    style: TextStyle(fontSize: 11.5, height: 1.4, color: AppColors.v3TextTertiary)),
              ],
            ),
          ],
          if (isOwner) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ZestButton(
                  key: const ValueKey('directory-token-new'),
                  label: l10n.directoryNewToken,
                  icon: LucideIcons.keyRound,
                  isLoading: _busy == 'token',
                  onPressed: idle ? _newToken : null,
                ),
                ZestButton(
                  key: const ValueKey('directory-off'),
                  label: l10n.directoryTurnOff,
                  icon: LucideIcons.powerOff,
                  variant: ZestButtonVariant.ghost,
                  isLoading: _busy == 'off',
                  onPressed: idle ? _turnOff : null,
                ),
              ],
            ),
          ],
          const SizedBox(height: 14),
          _Subheading(l10n.directoryGroups),
          if (directory.groups.isEmpty)
            Text(l10n.directoryGroupsEmpty, style: TextStyle(fontSize: 12, color: AppColors.v3TextSecondary))
          else
            for (final g in directory.groups)
              Padding(
                key: ValueKey('directory-group-${g.id}'),
                padding: const EdgeInsets.only(bottom: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                Row(
                  children: [
                    // Opens to who is in it.
                    IconButton(
                      key: ValueKey('directory-group-open-${g.id}'),
                      tooltip: _open.contains(g.id) ? l10n.directoryHidePeople : l10n.directoryShowPeople,
                      visualDensity: VisualDensity.compact,
                      icon: Icon(_open.contains(g.id) ? LucideIcons.chevronDown : LucideIcons.chevronRight, size: 16),
                      onPressed: () => setState(() {
                        if (!_open.remove(g.id)) {
                          _open.add(g.id);
                          _groupPeople[g.id] = _api.groupPeople(_orchardId, g.id);
                        }
                      }),
                    ),
                    Expanded(
                      child: Text(l10n.directoryGroupLine(g.name, g.members),
                          style: TextStyle(fontSize: 12.5, color: AppColors.v3TextPrimary)),
                    ),
                    if (_busy == g.id)
                      const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.6))
                    else
                      // The app's select (it was a Material dropdown
                      // before).
                      ZestSelect<String?>(
                        value: roles.contains(g.role) ? g.role : null,
                        width: 160,
                        onChanged: isOwner && idle ? (r) => _mapGroup(g, r) : null,
                        items: [for (final r in roles) ZestSelectItem(r, _roleLabel(r, l10n))],
                      ),
                  ],
                ),
                if (_open.contains(g.id))
                  _GroupPeople(
                    key: ValueKey('directory-group-people-${g.id}'),
                    people: _groupPeople[g.id]!,
                    roleLabel: (r) => _roleLabel(r, l10n),
                  ),
                  ],
                ),
              ),
          // Whether the directory may lower a role too: off unless an
          // owner turns it on (a directory
          // gives on join and may raise, never takes a role back).
          if (isOwner) ...[
            const SizedBox(height: 14),
            Row(
              key: const ValueKey('directory-lowers'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l10n.directoryLowers,
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.v3TextPrimary)),
                      const SizedBox(height: 2),
                      Text(l10n.directoryLowersBody,
                          style: TextStyle(fontSize: 12, height: 1.45, color: AppColors.v3TextSecondary)),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                if (_busy == 'lowers')
                  const Padding(
                    padding: EdgeInsets.all(4),
                    child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.6)),
                  )
                else
                  ZestSwitch(
                    key: const ValueKey('directory-lowers-switch'),
                    value: directory.lowers,
                    onChanged: idle ? _setLowers : null,
                  ),
              ],
            ),
            // Directory groups become roles (3.3.0): made on an owner's
            // device, since only an owner signs a role into the record.
            const SizedBox(height: 14),
            Row(
              key: const ValueKey('directory-auto-roles'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l10n.directoryAutoRoles,
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.v3TextPrimary)),
                      const SizedBox(height: 2),
                      Text(l10n.directoryAutoRolesBody,
                          style: TextStyle(fontSize: 12, height: 1.45, color: AppColors.v3TextSecondary)),
                      if (directory.autoRoles && directory.groups.any((g) => g.role == null)) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 10,
                          runSpacing: 6,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              l10n.directoryAutoRolesWaiting(directory.groups.where((g) => g.role == null).length),
                              key: const ValueKey('directory-auto-roles-waiting'),
                              style: TextStyle(fontSize: 12, color: AppColors.v3TextPrimary),
                            ),
                            TextButton(
                              key: const ValueKey('directory-auto-roles-now'),
                              onPressed: idle ? _makeRolesNow : null,
                              child: Text(l10n.directoryAutoRolesMakeNow),
                            ),
                          ],
                        ),
                        if ((_people?.roles.length ?? 0) >= kMaxOrchardRoles)
                          Text(l10n.directoryAutoRolesFull(kMaxOrchardRoles),
                              key: const ValueKey('directory-auto-roles-full'),
                              style: TextStyle(fontSize: 12, height: 1.45, color: AppColors.v3TextTertiary)),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                if (_busy == 'auto-roles')
                  const Padding(
                    padding: EdgeInsets.all(4),
                    child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.6)),
                  )
                else
                  ZestSwitch(
                    key: const ValueKey('directory-auto-roles-switch'),
                    value: directory.autoRoles,
                    onChanged: idle ? _setAutoRoles : null,
                  ),
              ],
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(child: _Subheading(l10n.directoryChanges)),
              if (directory.pending.length > 1)
                TextButton(
                  key: const ValueKey('directory-set-aside-all'),
                  onPressed: idle ? () => _setAsideAll(directory.pending) : null,
                  child: Text(l10n.directorySetAsideAll),
                ),
              if (directory.pending.where((c) => c.kind == DirectoryChangeKind.add && c.role != null).length > 1)
                teamButton(
                  key: const ValueKey('directory-invite-all'),
                  kind: TeamButtonKind.primary,
                  icon: LucideIcons.userPlus,
                  label: l10n.directoryInviteAll(
                      directory.pending.where((c) => c.kind == DirectoryChangeKind.add && c.role != null).length),
                  onPressed: idle
                      ? () => _inviteAll([
                            for (final c in directory.pending)
                              if (c.kind == DirectoryChangeKind.add && c.role != null) c,
                          ])
                      : null,
                ),
            ],
          ),
          if (directory.pending.isEmpty)
            Text(l10n.directoryChangesEmpty, style: TextStyle(fontSize: 12, color: AppColors.v3TextSecondary))
          else
            for (final c in directory.pending) _changeRow(c, l10n, idle),
          if (directory.held.isNotEmpty) ...[
            const SizedBox(height: 14),
            _Subheading(l10n.directoryHeld),
            for (final h in directory.held)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(h.email.isEmpty ? h.uid : h.email,
                    style: TextStyle(fontSize: 12.5, color: AppColors.v3TextSecondary)),
              ),
          ],
        ],
        if (_error != null) ...[const SizedBox(height: 8), _ErrorLine(_error!)],
      ],
    );
  }
}

/// Who is in a directory group, each with where they stand.
class _GroupPeople extends ConsumerWidget {
  const _GroupPeople({super.key, required this.people, required this.roleLabel});

  final Future<List<DirectoryPerson>> people;
  final String Function(String? role) roleLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    ref.watch(recordingModeProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(40, 2, 0, 6),
      child: FutureBuilder<List<DirectoryPerson>>(
        future: people,
        builder: (context, snap) {
          if (snap.hasError) {
            return Text(l10n.directoryPeopleError,
                style: TextStyle(fontSize: 12, color: AppColors.v3Error));
          }
          final list = snap.data;
          if (list == null) {
            return const Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.6)),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final p in list)
                Padding(
                  key: ValueKey('directory-person-${p.email}'),
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: RedactedText(Redactable.account(p.email),
                            style: TextStyle(fontSize: 12.5, color: AppColors.v3TextPrimary)),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        !p.active
                            ? l10n.directoryPersonOff
                            : switch (p.state) {
                                DirectoryPersonState.member => roleLabel(p.role),
                                DirectoryPersonState.waiting => l10n.directoryPersonWaiting,
                                DirectoryPersonState.invited => l10n.directoryPersonInvited,
                                DirectoryPersonState.outside => l10n.directoryPersonOutside,
                              },
                        style: TextStyle(
                            fontSize: 12,
                            color: p.state == DirectoryPersonState.waiting
                                ? AppColors.v3Warning
                                : AppColors.v3TextSecondary),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _ChangeRow extends StatelessWidget {
  const _ChangeRow({
    super.key,
    required this.text,
    required this.busy,
    required this.actLabel,
    this.onAct,
    this.onSetAside,
  });

  final String text;
  final bool busy;
  final String actLabel;
  final VoidCallback? onAct;
  final VoidCallback? onSetAside;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.v3BorderSubtle),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(child: Text(text, style: TextStyle(fontSize: 12.5, height: 1.4, color: AppColors.v3TextPrimary))),
          if (busy)
            const Padding(
              padding: EdgeInsets.all(8),
              child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.6)),
            )
          else ...[
            TextButton(onPressed: onAct, child: Text(actLabel)),
            TextButton(onPressed: onSetAside, child: Text(l10n.directorySetAside)),
          ],
        ],
      ),
    );
  }
}

class _CopyRow extends StatelessWidget {
  const _CopyRow({super.key, required this.label, required this.value, this.secret = false});

  final String label;
  final String value;

  /// Whether [value] lets whoever holds it act for the team (the directory's
  /// token): copied as a secret is, so it leaves the clipboard by itself, and
  /// the person is told (found in a security review: it was a plain copy).
  final bool secret;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 11.5, color: AppColors.v3TextSecondary)),
        Row(
          children: [
            Expanded(child: SelectableText(value, style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12))),
            IconButton(
              icon: const Icon(LucideIcons.copy, size: 14),
              tooltip: l10n.copy,
              visualDensity: VisualDensity.compact,
              onPressed: () async {
                if (secret) {
                  await SecretClipboard.copy(value);
                } else {
                  await Clipboard.setData(ClipboardData(text: value));
                }
                if (context.mounted) {
                  showTopSnackBar(context, secret ? clearsSoon(l10n, l10n.ssoCopied) : l10n.ssoCopied, isSuccess: true);
                }
              },
            ),
          ],
        ),
      ],
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.icon, required this.color, required this.text});

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 15, color: color)),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(fontSize: 12.5, height: 1.4, color: AppColors.v3TextPrimary))),
        ],
      );
}

class _Subheading extends StatelessWidget {
  const _Subheading(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(label, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppColors.v3TextPrimary)),
      );
}

class _ErrorLine extends StatelessWidget {
  const _ErrorLine(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(text,
      key: const ValueKey('directory-error'), style: TextStyle(fontSize: 12, height: 1.4, color: AppColors.v3Error));
}
