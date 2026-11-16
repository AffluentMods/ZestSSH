import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/watch/session_watch.dart';
import 'package:zestssh/features/orchards/watch/watch_gate.dart';
import 'package:zestssh/features/sharing/session_shares.dart';
import 'package:zestssh/features/sharing/share_host.dart';
import 'package:zestssh/features/sharing/share_nudges.dart';
import 'package:zestssh/features/sharing/share_providers.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/ui/screens/sharing/share_invitations.dart';
import 'package:zestssh/ui/screens/sharing/share_widgets.dart';
import 'package:zestssh/ui/screens/sharing/watch_ui.dart';

/// Session sharing in the running app (3.0): invitations are looked at when
/// ZestSSH Cloud says one came or went, when an Orchard opens on this device
/// and when the app comes to the front; a new one is announced; a request
/// for the keyboard is announced; and signing out ends everything shared
/// and watched from here.
///
/// What is announced names nobody and no host: the bell keeps its history
/// outside the encrypted database.
class ShareAppHooks {
  ShareAppHooks(this._ref, this._context);

  final WidgetRef _ref;

  /// A context under the app's navigator, to open a dialog from a notice.
  final BuildContext? Function() _context;

  StreamSubscription<void>? _nudges;
  ProviderSubscription<Map<String, AppDatabase>>? _orchards;
  ProviderSubscription<Object?>? _account;

  void start() {
    if (!kOrchardsEnabled || _nudges != null) return;
    final invitations = _ref.read(shareInvitationsProvider.notifier);
    invitations.onNew = _announce;
    _nudges = shareInviteNudges.stream.listen((_) => unawaited(invitations.refresh()));
    _orchards = _ref.listenManual(orchardDatabasesProvider, (prev, next) {
      // An Orchard opened here: what waits in it can be opened now. One that
      // closed (the app locked): what was listed for it goes.
      if (next.length != (prev?.length ?? 0)) unawaited(invitations.refresh());
    }, fireImmediately: true);
    _account = _ref.listenManual<Object?>(currentUserProvider, (prev, next) {
      if (prev != null && next == null) unawaited(signedOut());
    });
    shareNoticeHandler = _noted;
    // Watched Crates: whom to ask to watch, and what happens to a
    // watched session of this device.
    watchAskHandler = _askToWatch;
    watchNoticeHandler = _watchNoted;
    // And, while ZestSSH Cloud cannot be reached, why someone who may goes
    // on with nobody watching (the outage work).
    unwatchedAskHandler = _askWhyUnwatched;
    _ref.read(shareTmuxJoinsProvider).onEnded = (_, _) {
      _ref.read(notificationCenterProvider.notifier).info(gl10n.shareTmuxStoppedNotice);
    };
  }

  void stop() {
    unawaited(_nudges?.cancel());
    _nudges = null;
    _orchards?.close();
    _orchards = null;
    _account?.close();
    _account = null;
    // (Compared with ==: every mention of a method makes a new object, so
    // two of them are equal and never identical.)
    if (shareNoticeHandler == _noted) shareNoticeHandler = null;
    if (watchAskHandler == _askToWatch) watchAskHandler = null;
    if (watchNoticeHandler == _watchNoted) watchNoticeHandler = null;
    if (unwatchedAskHandler == _askWhyUnwatched) unwatchedAskHandler = null;
  }

  /// Whom to ask to watch a session to a watched Crate's host: asked on
  /// whatever screen is in front. With no screen there is nobody to ask,
  /// and the session does not start.
  Future<Set<String>?> _askToWatch(WatchRequest request) async {
    final context = _context();
    if (context == null) return null;
    return showWatchAsk(context, request);
  }

  /// The sessions whose person is being asked why they go on.
  final _askingWhy = <String>{};

  /// Why someone goes on with nobody watching, ZestSSH Cloud being away:
  /// asked on whatever screen is in front. With no screen there is nobody
  /// to ask, and nothing goes on. One question for a session at a time: a
  /// second one, while the first is open, is given up.
  Future<String?> _askWhyUnwatched(UnwatchedRequest request) async {
    final context = _context();
    if (context == null || !_askingWhy.add(request.sessionId)) return null;
    try {
      return await showUnwatchedAsk(context, request);
    } finally {
      _askingWhy.remove(request.sessionId);
    }
  }

  /// A watched session is held or was closed: said where the person sees
  /// it whatever tab is in front. One word per session, which goes when
  /// someone watches again.
  void _watchNoted(String sessionId, WatchNote note) {
    final center = _ref.read(notificationCenterProvider.notifier);
    final id = 'watch-held-$sessionId';
    switch (note) {
      case WatchNote.held:
        center.show(AppNotification(
          id: id,
          title: gl10n.watchHeldNotice,
          severity: NotificationSeverity.warning,
          dismissAfter: const Duration(seconds: 12),
        ));
      case WatchNote.watchedAgain:
        center.remove(id);
      // Let go on with nobody watching (ZestSSH Cloud cannot be reached):
      // typing is held no longer, and whoever let it go on has just said why.
      case WatchNote.unwatched:
        center.remove(id);
      case WatchNote.closedUnwatched:
        center.remove(id);
        center.warning(gl10n.watchClosedNotice, dismissAfter: const Duration(seconds: 20));
    }
  }

  /// The app came to the front: an invitation that arrived meanwhile shows.
  void onForeground() {
    if (!kOrchardsEnabled || _nudges == null) return;
    unawaited(_ref.read(shareInvitationsProvider.notifier).refresh());
  }

  /// Signed out: nothing is shared or watched from this device any more.
  Future<void> signedOut() async {
    _ref.read(shareInvitationsProvider.notifier).clear();
    await SessionShares.stopAll();
    await ShareViews.closeAll();
    await _ref.read(shareTmuxJoinsProvider).leaveAll();
  }

  void _announce(IncomingShare share) {
    _ref.read(notificationCenterProvider.notifier).show(AppNotification(
          // One per share: a second word about it takes the place of the first.
          id: 'share-invite-${share.shareId}',
          // Asked to watch a session of a watched Crate: said as that,
          // since the session waits for them.
          title: share.asksToWatch ? gl10n.shareWatchNoticeTitle : gl10n.shareInviteNoticeTitle,
          body: gl10n.shareInviteNoticeBody,
          dismissAfter: const Duration(seconds: 20),
          actionLabel: gl10n.shareInviteNoticeView,
          onAction: () {
            final context = _context();
            if (context != null) unawaited(showShareInvitations(context));
          },
        ));
  }

  void _noted(String sessionId, ShareNote note, String? who) {
    final center = _ref.read(notificationCenterProvider.notifier);
    switch (note) {
      case ShareNote.askedKeyboard:
        center.show(AppNotification(
          id: 'share-keyboard-$sessionId',
          title: gl10n.shareKeyboardNoticeTitle,
          body: gl10n.shareKeyboardNoticeBody,
          severity: NotificationSeverity.warning,
          dismissAfter: const Duration(seconds: 20),
          actionLabel: gl10n.shareInviteNoticeView,
          onAction: () {
            final context = _context();
            if (context != null) unawaited(showShareParticipants(context, sessionId));
          },
        ));
      case ShareNote.endedElsewhere:
        center.warning(gl10n.shareStoppedNotice, dismissAfter: const Duration(seconds: 12));
      case ShareNote.endAsked:
        center.warning(gl10n.shareEndedByNotice, dismissAfter: const Duration(seconds: 20));
      case ShareNote.joined ||
            ShareNote.left ||
            ShareNote.declined ||
            ShareNote.keyboardGiven ||
            ShareNote.keyboardBack ||
            ShareNote.stopped:
        break;
    }
  }
}
