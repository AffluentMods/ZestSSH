import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/account_sign_out.dart';
import 'package:zestssh/providers/profile_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/services/desktop_browser_sign_in.dart' show BrowserConfirm;
import 'package:zestssh/services/profiles/profile_list.dart' show ProfileEntry;
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/profile/account_sign_in.dart';
import 'package:zestssh/ui/screens/profile/profile_screen.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';

// Accounts on one computer (to-do 60, stage 3): what the account row's list does.
// Whatever goes wrong or is cancelled, the person stays where they were.

/// What opens at the control it is for, over the app with a clear barrier, closed by a
/// click beside it or Escape: a menu or a popover, not a dialog (no dialog's title,
/// footer or buttons to keep), so not the dialog shell. [build] is given the route's own
/// context, to close it. Under [showAnchoredPanel], and the plan popover beside its chip
/// (showPlanPopover).
Future<T?> showAtControl<T>(BuildContext context, {required String label, required WidgetBuilder build}) {
  return showGeneralDialog<T>(
    context: context,
    barrierColor: Colors.transparent,
    barrierDismissible: true,
    barrierLabel: label,
    transitionDuration: const Duration(milliseconds: 90),
    pageBuilder: (routeContext, _, _) => build(routeContext),
  );
}

/// A panel under or over [anchor], closed by a click beside it or Escape: the account
/// row's list, and the space switcher.
Future<T?> showAnchoredPanel<T>(
  BuildContext context, {
  required Rect anchor,
  required Widget child,
  required String label,
  double width = 320,
  bool above = false,
}) {
  return showAtControl<T>(
    context,
    label: label,
    build: (_) => LayoutBuilder(
      builder: (_, box) {
        final screen = box.biggest;
        final left = anchor.left.clamp(8.0, (screen.width - width - 8).clamp(8.0, double.infinity));
        return Stack(
          children: [
            Positioned(
              left: left,
              top: above ? null : anchor.bottom + 4,
              bottom: above ? screen.height - anchor.top + 4 : null,
              width: width,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: above ? anchor.top - 12 : screen.height - anchor.bottom - 12),
                child: Material(
                  color: AppColors.v3Surface,
                  elevation: 8,
                  borderRadius: BorderRadius.circular(10),
                  clipBehavior: Clip.antiAlias,
                  child: SingleChildScrollView(padding: const EdgeInsets.symmetric(vertical: 6), child: child),
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}

/// The rectangle of what [context] draws, on the screen; null where it has no size yet.
Rect? rectOf(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}

/// The account row at the bottom left: on a computer the list of its accounts and guest
/// data, and on a phone or tablet the account's page, as ever.
Future<void> openAccountRow(BuildContext context, WidgetRef ref) async {
  if (!ref.read(profileControllerProvider).on) return ProfileScreen.openAccount(context, ref);
  final anchor = rectOf(context);
  if (anchor == null) return ProfileScreen.openAccount(context, ref);
  await showAnchoredPanel<void>(
    context,
    anchor: anchor,
    above: true,
    label: AppLocalizations.of(context)!.accountListLabel,
    child: AccountList(outer: context, outerRef: ref, manage: true),
  );
}

/// The list of this computer's accounts and guest data, the one in use marked, with
/// Add account: the same in the account row's panel and the space switcher.
class AccountList extends StatelessWidget {
  const AccountList({super.key, required this.outer, required this.outerRef, this.manage = false});

  /// Where what is picked goes on from: the panel closes first.
  final BuildContext outer;
  final WidgetRef outerRef;

  /// Manage account and Sign out as well (the account row; the space switcher has
  /// no business with them).
  final bool manage;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final profiles = outerRef.read(profileControllerProvider);
    void act(Future<void> Function() then) {
      Navigator.of(context).pop();
      unawaited(then());
    }

    final signedIn = !profiles.guestDataOnScreen;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final a in profiles.accountsHere)
          AccountListRow(
            key: ValueKey('account-row-${a.id}'),
            name: a.label,
            mask: true,
            subtitle: accountRowWords(a, l10n),
            inUse: a.inUse,
            onTap: a.inUse || a.lost ? null : () => act(() => pickAccount(outer, outerRef, a)),
            onRemove: () => act(() => removeAccount(outer, outerRef, a)),
            removeLabel: l10n.accountRemoveAction,
          ),
        AccountListRow(
          key: const ValueKey('account-row-guest'),
          name: l10n.narrowSidebarGuest,
          subtitle: l10n.railGuestLocal,
          inUse: profiles.guestDataOnScreen,
          onTap: profiles.guestDataOnScreen ? null : () => act(() => pickGuestData(outer, outerRef)),
        ),
        for (final kept in profiles.keptGuestData)
          AccountListRow(
            key: ValueKey('account-row-kept-${kept.id}'),
            name: l10n.narrowSidebarGuest,
            subtitle: l10n.accountRowKeptGuest,
            inUse: false,
            onTap: () => act(() => pickGuestData(outer, outerRef, kept: kept)),
          ),
        const Divider(height: 10),
        // (A build with no account service has no account to add.)
        if (zestHasCloud)
          AccountMenuAction(
            key: const ValueKey('account-add'),
            icon: LucideIcons.userPlus,
            label: l10n.accountAddAction,
            onTap: () => act(() => addAccount(outer, outerRef)),
          ),
        if (manage)
          AccountMenuAction(
            key: const ValueKey('account-manage'),
            icon: LucideIcons.settings,
            label: l10n.accountManageAction,
            onTap: () => act(() => ProfileScreen.openAccount(outer, outerRef)),
          ),
        if (manage && signedIn)
          AccountMenuAction(
            key: const ValueKey('account-sign-out'),
            icon: LucideIcons.logOut,
            label: l10n.treeSelectorSignOut,
            onTap: () => act(() => confirmAndSignOut(outer, outerRef)),
          ),
      ],
    );
  }
}

/// What the list says of [a].
String accountRowWords(ComputerAccount a, AppLocalizations l10n) {
  if (a.inUse) return l10n.accountRowInUse;
  if (a.lost) return l10n.accountRowLost;
  if (a.signedOut) return l10n.accountRowSignedOut;
  return a.needsSignIn ? l10n.accountRowAsksSignIn : l10n.accountRowSignedIn;
}

/// One account in the list: its name, how it stands, a check on the one in use, and
/// its Remove, always in reach, as the words at the sixth account send people to it.
class AccountListRow extends StatelessWidget {
  const AccountListRow({
    super.key,
    required this.name,
    required this.subtitle,
    required this.inUse,
    this.mask = false,
    this.onTap,
    this.onRemove,
    this.removeLabel,
  });

  final String name;
  final String subtitle;
  final bool inUse;

  /// It is someone's name or address: masked in recording mode.
  final bool mask;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;
  final String? removeLabel;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(fontSize: 13, color: AppColors.v3TextPrimary);
    final initial = mask ? null : name.characters.first.toUpperCase();
    final rowKey = key;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Row(
          children: [
            CircleAvatar(
              radius: 12,
              backgroundColor: AppColors.v3AccentPrimary.withValues(alpha: 0.12),
              child: initial != null
                  ? Text(initial, style: TextStyle(fontSize: 11, color: AppColors.v3AccentInk))
                  : Icon(LucideIcons.user, size: 12, color: AppColors.v3AccentInk),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (mask)
                    RedactedText(Redactable.account(name), style: style, overflow: TextOverflow.ellipsis)
                  else
                    Text(name, style: style, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10.5, color: AppColors.v3TextTertiary),
                  ),
                ],
              ),
            ),
            if (inUse) ...[
              const SizedBox(width: 6),
              Icon(LucideIcons.check, size: 14, color: AppColors.v3AccentInk),
            ],
            if (onRemove != null) ...[
              const SizedBox(width: 6),
              Tooltip(
                message: removeLabel ?? '',
                child: InkResponse(
                  key: rowKey is ValueKey<String> ? ValueKey('${rowKey.value}-remove') : null,
                  onTap: onRemove,
                  radius: 14,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(LucideIcons.trash2, size: 14, color: AppColors.v3TextTertiary),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// An action under the list.
class AccountMenuAction extends StatelessWidget {
  const AccountMenuAction({super.key, required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              SizedBox(width: 24, child: Icon(icon, size: 14, color: AppColors.v3TextSecondary)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(label, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: AppColors.v3TextPrimary)),
              ),
            ],
          ),
        ),
      );
}

// ── What each one does ───────────────────────────────────────────────

void _backToShell(BuildContext context) {
  if (context.mounted) GoRouter.maybeOf(context)?.go(Routes.home);
}

/// What closes for a switch, said first where anything is open: how many sessions, and
/// what becomes of them. False where the person stayed.
Future<bool> _sayWhatCloses(BuildContext context, WidgetRef ref, String name) async {
  final count = ref.read(profileControllerProvider).openSessions;
  if (count == 0) return true;
  final l10n = AppLocalizations.of(context)!;
  // What ends with the sessions, in its amber sentence (the whole dialog
  // was yellow).
  final ok = await ZestConfirmDialog.show(
    context,
    tone: ZestDialogTone.warning,
    title: l10n.accountSwitchTitle(name),
    body: '',
    warning: l10n.accountSwitchSessionsClose(count),
    confirmLabel: l10n.accountSwitchConfirm,
  );
  return ok == true;
}

/// Runs [change] with the app covered, says how it ended, and on success goes back to
/// the shell.
Future<void> _switchShowing(BuildContext context, WidgetRef ref, String name, Future<void> Function() change) async {
  final l10n = AppLocalizations.of(context)!;
  final navigator = Navigator.of(context, rootNavigator: true);
  final opening = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    useSafeArea: false,
    builder: (_) => PopScope(canPop: false, child: _Opening(name)),
  );
  unawaited(navigator.push(opening));
  Object? failed;
  try {
    await change();
  } catch (e) {
    failed = e;
  }
  // This one exactly: what the opened profile asks may be over it by now.
  navigator.removeRoute(opening);
  if (!context.mounted) return;
  if (failed == null) {
    _backToShell(context);
    showTopSnackBar(context, l10n.accountSwitchedTo(name), isSuccess: true);
    return;
  }
  AppLogger.warning('A switch of account stopped (${errorKind(failed)})');
  showTopSnackBar(
    context,
    ErrorCodes.withCode(l10n.accountSwitchFailedBody, ErrorCodes.accountSwitchFailed),
    isError: true,
    details: '$failed',
  );
}

class _Opening extends StatelessWidget {
  const _Opening(this.name);

  final String name;

  @override
  Widget build(BuildContext context) => Center(
        child: Material(
          color: AppColors.v3Surface,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 12),
                Text(AppLocalizations.of(context)!.accountSwitching(name), style: TextStyle(fontSize: 13, color: AppColors.v3TextPrimary)),
              ],
            ),
          ),
        ),
      );
}

/// [account] was picked from the list. A signed-in account of the same person opens at
/// once; one signed out, or someone else's, takes its own sign-in,
/// which says on the sign-in page that it is that account's to confirm.
Future<void> pickAccount(BuildContext context, WidgetRef ref, ComputerAccount account) async {
  if (account.inUse || account.lost) return;
  if (account.needsSignIn) {
    final opened = await _signInAs(context, ref, account);
    if (opened && context.mounted) _backToShell(context);
    return;
  }
  final name = Redactable.account(account.label).displayIn(ref);
  if (!await _sayWhatCloses(context, ref, name) || !context.mounted) return;
  final profiles = ref.read(profileControllerProvider);
  await _switchShowing(context, ref, name, () => profiles.switchTo(account.id));
}

Future<bool> _signInAs(BuildContext context, WidgetRef ref, ComputerAccount? account, {SignInSaid said = SignInSaid.nothing}) async {
  if (!signsInOnDevice) {
    return signInInBrowser(
      context,
      ref,
      confirm: account == null || account.label.isEmpty ? null : BrowserConfirm(account.label),
      onlyFor: account?.entry.uid,
      onlyForName: account == null ? null : Redactable.account(account.label).displayIn(ref),
      said: said,
    );
  }
  // A Mac signs in with its own ways. What it signs in as is what opens. (Through
  // Firebase it cannot carry [said]: what is under way decides, [ProfileController].)
  final way = await showSignInWays(context);
  if (way == null || !context.mounted) return false;
  return signInWith(context, ref, way);
}

/// Guest data was picked: the one guest data, or ([kept]) what was set aside when a
/// deleted account's data became the guest data. On a Mac whose Firebase holds the
/// account on screen nothing else would stop it coming back, so this is its sign-out.
Future<void> pickGuestData(BuildContext context, WidgetRef ref, {ProfileEntry? kept}) async {
  final l10n = AppLocalizations.of(context)!;
  final profiles = ref.read(profileControllerProvider);
  if (profiles.heldByFirebase) return confirmAndSignOut(context, ref);
  final name = l10n.narrowSidebarGuest;
  if (!await _sayWhatCloses(context, ref, name) || !context.mounted) return;
  await _switchShowing(context, ref, name, () => kept == null ? profiles.switchToGuest() : profiles.switchTo(kept.id));
}

/// What the person said to "Whose account is this?". Closing it says neither, and
/// nothing opens.
enum _AccountWhose { mine, someoneElse }

/// Add account: the room for it is said at once, whose it is asked, then the
/// sign-in. A new account gets a profile of its own and the guest-data question, as any
/// first sign-in here does. Cancelled or failed, nothing changes.
Future<void> addAccount(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context)!;
  final profiles = ref.read(profileControllerProvider);
  if (!profiles.roomForAnotherAccount) {
    // How to make room: a notice (it was yellow), and Got it (it said OK).
    await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.info,
      title: l10n.accountsFullTitle,
      body: ErrorCodes.withCode(l10n.accountsFullBody, ErrorCodes.tooManyAccounts),
      confirmLabel: l10n.desktopGotIt,
      showCancel: false,
    );
    return;
  }
  var said = SignInSaid.nothing;
  if (profiles.addAsksWhose) {
    final whose = await ZestConfirmDialog.ask<_AccountWhose>(
      context,
      tone: ZestDialogTone.neutral,
      title: l10n.accountWhoseTitle,
      body: l10n.accountWhoseBody,
      confirmLabel: l10n.accountWhoseMine,
      confirm: _AccountWhose.mine,
      cancelLabel: l10n.accountWhoseOther,
      cancel: _AccountWhose.someoneElse,
    );
    if (whose == null || !context.mounted) return;
    said = await profiles.nextSignInIs(mine: whose == _AccountWhose.mine);
    if (!context.mounted) return profiles.forgetNextSignIn(said);
  }
  try {
    final added = await _signInAs(context, ref, null, said: said);
    if (added && context.mounted) _backToShell(context);
  } finally {
    profiles.forgetNextSignIn(said);
  }
}

/// Remove from this computer: what goes and what stays is said first.
Future<void> removeAccount(BuildContext context, WidgetRef ref, ComputerAccount account) async {
  final l10n = AppLocalizations.of(context)!;
  final profiles = ref.read(profileControllerProvider);
  final name = Redactable.account(account.label).displayIn(ref);
  if (account.someoneElses && !account.lost) {
    // Someone else's data goes only with their sign-in: signed in from the
    // list, it is on screen, and Remove takes it from there.
    await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.info,
      title: l10n.accountRemoveTitle(name),
      body: l10n.accountRemoveSomeoneElses(name),
      confirmLabel: l10n.desktopGotIt,
      showCancel: false,
    );
    return;
  }
  final yes = await ZestConfirmDialog.show(
    context,
    tone: ZestDialogTone.destructive,
    title: l10n.accountRemoveTitle(name),
    body: [
      l10n.accountRemoveBody,
      // A signed-out account has no session to say so with.
      if (account.signedOut && !account.lost) l10n.accountRemoveCopyStays,
      if (account.inUse) l10n.accountRemoveGuestOpens,
      if (account.inUse && profiles.openSessions > 0) l10n.signOutSessionsClose(profiles.openSessions),
    ].join('\n\n'),
    confirmLabel: l10n.commonRemove,
  );
  if (yes != true || !context.mounted) return;
  try {
    final gone = await profiles.removeFromComputer(account.id);
    if (!context.mounted) return;
    if (gone) {
      showTopSnackBar(context, l10n.accountRemoved(name), isSuccess: true);
    } else {
      showTopSnackBar(context, ErrorCodes.withCode(l10n.accountRemoveLater, ErrorCodes.accountNotRemoved), isError: true);
    }
    if (account.inUse) _backToShell(context);
  } catch (e) {
    AppLogger.warning('An account was not removed (${errorKind(e)})');
    if (context.mounted) {
      showTopSnackBar(
        context,
        ErrorCodes.withCode(l10n.accountSwitchFailedBody, ErrorCodes.accountSwitchFailed),
        isError: true,
        details: '$e',
      );
    }
  }
}

/// Show a confirmation, then sign the account out of this device
/// ([signOutAccount]: the Firebase session on mobile, the browser session
/// token on desktop, cached entitlements and sync keys). Local SSH data
/// stays put; signing in again restores everything.
Future<void> confirmAndSignOut(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context)!;
  final profiles = ref.read(profileControllerProvider);
  final confirmed = await ZestConfirmDialog.show(
    context,
    tone: ZestDialogTone.neutral,
    title: l10n.treeSelectorSignOutQuestion,
    body: profiles.on
        ? [
            l10n.signOutLocksBody,
            if (profiles.openSessions > 0) l10n.signOutSessionsClose(profiles.openSessions),
          ].join('\n\n')
        : l10n.treeSelectorSignOutBody,
    confirmLabel: l10n.treeSelectorSignOutConfirm,
  );
  if (confirmed != true || !context.mounted) return;
  try {
    await signOutAccount(ref);
    if (!context.mounted) return;
    showTopSnackBar(context, l10n.treeSelectorSignedOut);
  } catch (e) {
    if (!context.mounted) return;
    showTopSnackBar(context, l10n.treeSelectorNotSignedOut, isError: true, details: '$e');
  }
}
