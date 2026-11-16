import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/utils/platform_utils.dart';

import 'models/app_notification.dart';

/// Maximum entries kept in history before the oldest are evicted. 200 matches
/// the mobile notifications retention cap (spec: 200 or 30 days, whichever comes
/// first); the list view stays cheap to render at this size.
const int _maxHistory = 200;

/// Entries older than this are pruned on load + save so the persisted history
/// cannot grow without bound over time.
const int _maxHistoryAgeDays = 30;

/// Maximum simultaneously-visible toasts. Above this we queue and
/// release as older ones dismiss, so a flood of notifications can't
/// blanket the entire viewport.
const int _maxConcurrentToasts = 4;

/// Snapshot of the notification center's full state. Held by
/// [NotificationCenter] and consumed by the bell + toast layer.
@immutable
class NotificationsState {
  const NotificationsState({
    this.history = const [],
    this.visibleToastIds = const {},
  });

  /// Most recent first. Capped at [_maxHistory].
  final List<AppNotification> history;

  /// IDs of notifications currently rendered as toasts. A notification
  /// in [history] is also in [visibleToastIds] only while its toast
  /// is on screen.
  final Set<String> visibleToastIds;

  /// What the bell counts: the warnings and errors not yet seen, the things
  /// to act on (before, it counted every notice, so each
  /// "Connected" and "Saved" made the count grow, though an info notice is
  /// said to show no unread dot). Info and success notices are in the list,
  /// marked unseen there ([anyUnseen]), and go by as toasts.
  int get unreadCount => history.where((n) => !n.isRead && n.severity.countsAsUnread).length;

  bool get hasUnread => unreadCount > 0;

  /// Whether any notice of any kind is not yet seen (Mark all read).
  bool get anyUnseen => history.any((n) => !n.isRead);

  /// All currently-visible toasts in show-order (oldest visible first).
  List<AppNotification> get visibleToasts {
    return [
      for (final n in history.reversed)
        if (visibleToastIds.contains(n.id)) n,
    ];
  }

  NotificationsState copyWith({
    List<AppNotification>? history,
    Set<String>? visibleToastIds,
  }) {
    return NotificationsState(
      history: history ?? this.history,
      visibleToastIds: visibleToastIds ?? this.visibleToastIds,
    );
  }
}

/// Singleton notification center. Riverpod-managed so widgets watch
/// it without needing a global. Spawns auto-dismiss timers, manages
/// the toast queue, and tracks read state.
class NotificationCenter extends Notifier<NotificationsState> {
  /// Active auto-dismiss timers keyed by notification id. Cancelled
  /// when the user manually dismisses, or on widget teardown.
  final Map<String, Timer> _timers = {};

  /// Pending notifications waiting for a toast slot. We never drop -
  /// they're shown in arrival order as slots free up.
  final Queue<String> _toastQueue = Queue();

  /// Listeners (typically the toast overlay) that need to know when a
  /// new notification has been pushed. Keeps the overlay decoupled
  /// from this notifier - the overlay only listens, never reads
  /// state directly.
  final List<void Function(AppNotification)> _onShowListeners = [];

  @override
  NotificationsState build() {
    // Cancel any active timers when the provider rebuilds (rare, but
    // possible during hot reload).
    ref.onDispose(() {
      for (final t in _timers.values) {
        t.cancel();
      }
      _timers.clear();
    });
    // Restore persisted history (mobile: survives an app restart). Nothing is a
    // live toast on restart, so visibleToastIds stays empty.
    return NotificationsState(history: _loadPersisted());
  }

  /// Load + prune the persisted history. Parses PER ENTRY so one malformed row
  /// is dropped rather than wiping the whole history, de-dups by id (a corrupt
  /// blob with duplicate ids would otherwise crash the list's Dismissible
  /// keys), and returns empty on a total failure so a bad blob can never wedge
  /// startup.
  List<AppNotification> _loadPersisted() {
    try {
      final raw = ref.read(settingsServiceProvider).notificationHistory;
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final seen = <String>{};
      final out = <AppNotification>[];
      for (final e in decoded) {
        if (e is! Map) continue;
        try {
          final n = AppNotification.fromJson(e.cast<String, dynamic>());
          if (seen.add(n.id)) out.add(n);
        } catch (_) {
          // Skip just this corrupt row.
        }
      }
      return _prunedForPersist(out);
    } catch (_) {
      return const [];
    }
  }

  /// Persistable view of [items]: drop transient entries and anything older than
  /// [_maxHistoryAgeDays], newest first, capped at [_maxHistory].
  List<AppNotification> _prunedForPersist(List<AppNotification> items) {
    final cutoff =
        DateTime.now().subtract(const Duration(days: _maxHistoryAgeDays));
    final kept = [
      for (final n in items)
        if (!n.transient && n.createdAt.isAfter(cutoff)) n,
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return kept.length > _maxHistory ? kept.sublist(0, _maxHistory) : kept;
  }

  bool _persistScheduled = false;

  /// Schedule a write of the current history (best effort). Coalesced onto a
  /// microtask so a burst of mutations in one event-loop turn (e.g. many toasts
  /// arriving at once) serialises ONCE instead of re-encoding up to 200 entries
  /// per push on the UI isolate.
  void _persist() {
    if (_persistScheduled) return;
    _persistScheduled = true;
    scheduleMicrotask(() {
      _persistScheduled = false;
      try {
        final json = jsonEncode(
            _prunedForPersist(state.history).map((n) => n.toJson()).toList());
        // ignore: discarded_futures
        ref.read(settingsServiceProvider).setNotificationHistory(json);
      } catch (_) {
        // Storage failures must never break the in-memory notification flow.
      }
    });
  }

  // ── External API (call from anywhere) ────────────────────────────

  /// Push a notification. Returns its id so the caller can dismiss
  /// or replace it later (e.g. progress notifications that update
  /// in place).
  ///
  /// With [countRepeats], a notice that says the same as one still on
  /// screen is counted on that one, and its id is what comes back: for a
  /// plain message with no identity of its own (what a pressed button
  /// answers, what [info], [success], [warning] and [error] say). A notice
  /// shown under an id its caller chose is its own notice whatever it says:
  /// one "typing is held" for each session, one for each time access was
  /// given. It is never counted on another, nor another on it.
  String show(AppNotification rawNotification, {bool countRepeats = false}) {
    // Sanitise title/body at the sink: notification text can originate from
    // untrusted remote output (host banners, error strings). Strip control
    // chars + bidi overrides, collapse whitespace, and bound the length so
    // a crafted string can't spoof or inflate the UI.
    final notification = rawNotification.copyWith(
      title: _sanitizeText(rawNotification.title, _maxTitleLen),
      body: rawNotification.body == null
          ? null
          : _sanitizeText(rawNotification.body!, _maxBodyLen),
      // A line at a time, so each stays a line of its own.
      summary: rawNotification.summary
          ?.map((line) => _sanitizeText(line, _maxTitleLen))
          .where((line) => line.isNotEmpty)
          .toList(),
    );
    final id = notification.id;

    // The same thing said again while it still stands on screen is the same
    // notice: it is counted there, not stood under it a second time. (A
    // button pressed four times against a server that refused it left four
    // identical notices, one under the other.)
    if (countRepeats) {
      final standing = _standingSame(notification);
      if (standing != null) return _countOn(standing, notification);
      _countable.add(id);
    }

    // De-duplicate by id - replace if it's already in history.
    final existing = state.history.indexWhere((n) => n.id == id);
    final newHistory = [
      notification,
      for (var i = 0; i < state.history.length; i++)
        if (i != existing) state.history[i],
    ];
    // Cap at maxHistory.
    final trimmed = newHistory.length > _maxHistory
        ? newHistory.sublist(0, _maxHistory)
        : newHistory;

    state = state.copyWith(history: trimmed);
    _persist();

    // Surface as toast, queueing if at capacity.
    if (state.visibleToastIds.length < _maxConcurrentToasts) {
      _showToast(notification);
    } else {
      _toastQueue.add(id);
      // Sticky errors never auto-dismiss; a burst of them would jam every
      // slot forever and hide all later notifications. Free the oldest
      // sticky toast so the queue can always drain.
      _evictOldestStickyIfJammed();
    }

    return id;
  }

  /// The notices shown with `countRepeats`, the only ones a later one may
  /// be counted on. Forgotten with the notice.
  final Set<String> _countable = {};

  /// Whether notices are drawn where the app runs, each as a card in a
  /// corner of the window: on a computer. A phone keeps them as a list, with
  /// nothing standing on screen for a later one to be the same as.
  @visibleForTesting
  static bool? debugToastsDrawn;

  static bool get _toastsDrawn => debugToastsDrawn ?? desktopShellInUse;

  /// The notice that says the same as [n] and still stands on screen, or
  /// waits for room there: the same kind, title and text. Null when there is
  /// none, and for a notice with an action of its own (each "Undo" undoes
  /// its own thing), one that leaves no trace, and one sent again under its
  /// own id (it replaces itself).
  AppNotification? _standingSame(AppNotification n) {
    if (!_toastsDrawn || n.onAction != null || n.transient) return null;
    if (state.history.any((h) => h.id == n.id)) return null;
    for (final h in state.history) {
      // (Only on a notice that was itself shown to be counted on.)
      if (!_countable.contains(h.id)) continue;
      if (h.onAction != null || h.transient) continue;
      if (h.severity != n.severity || h.title != n.title || h.body != n.body) continue;
      if (h.actionLabel != n.actionLabel) continue;
      if (state.visibleToastIds.contains(h.id) || _toastQueue.contains(h.id)) return h;
    }
    return null;
  }

  /// Counts [again] on [standing], the notice on screen that says the same:
  /// it becomes the newest, unread, with what stands behind the latest time
  /// to copy, and stays as long again as it would have from now. Returns
  /// its id, which stands for [again] too.
  String _countOn(AppNotification standing, AppNotification again) {
    final counted = standing.copyWith(
      repeats: standing.repeats + again.repeats,
      createdAt: again.createdAt,
      isRead: false,
      details: again.details,
    );
    state = state.copyWith(history: [
      counted,
      for (final h in state.history)
        if (h.id != standing.id) h,
    ]);
    _persist();
    final timer = _timers.remove(standing.id);
    if (timer != null) {
      timer.cancel();
      _timers[standing.id] = Timer(counted.effectiveDismissDuration, () => dismissToast(standing.id));
    }
    return standing.id;
  }

  /// Max characters retained for a notification title / body after sanitising.
  static const _maxTitleLen = 120;
  static const _maxBodyLen = 500;

  static final _controlAndBidi = RegExp(
      '[\u0000-\u001F\u007F-\u009F\u202A-\u202E\u2066-\u2069]');
  static final _whitespaceRun = RegExp(r'\s+');

  static String _sanitizeText(String s, int maxLen) {
    final cleaned = s
        .replaceAll(_controlAndBidi, ' ')
        .replaceAll(_whitespaceRun, ' ')
        .trim();
    return cleaned.length > maxLen
        ? '${cleaned.substring(0, maxLen)}…'
        : cleaned;
  }

  /// If every visible toast is sticky (never auto-dismisses) and the queue
  /// has waiting notifications, dismiss the oldest sticky toast to guarantee
  /// forward progress. No-op while any visible toast will free its own slot.
  void _evictOldestStickyIfJammed() {
    if (_toastQueue.isEmpty) return;
    if (state.visibleToastIds.length < _maxConcurrentToasts) return;
    final visible = state.visibleToasts;
    final hasAutoDismiss =
        visible.any((n) => n.effectiveDismissDuration > Duration.zero);
    if (hasAutoDismiss || visible.isEmpty) return;
    // visibleToasts is oldest-first; dismissToast frees the slot, marks it
    // read (it stays in the bell), and drains the queue into the free slot.
    dismissToast(visible.first.id);
  }

  /// Convenience constructor - wraps the [AppNotification] boilerplate.
  String info(String title, {String? body, Duration? dismissAfter}) {
    return show(AppNotification(
      id: const Uuid().v4(),
      title: title,
      body: body,
      severity: NotificationSeverity.info,
      dismissAfter: dismissAfter,
    ), countRepeats: true);
  }

  String success(String title, {String? body, Duration? dismissAfter}) {
    return show(AppNotification(
      id: const Uuid().v4(),
      title: title,
      body: body,
      severity: NotificationSeverity.success,
      dismissAfter: dismissAfter,
    ), countRepeats: true);
  }

  /// [details]: what stands behind it, already the report Copy details
  /// copies (ErrorReport.build: scrubbed).
  String warning(String title, {String? body, Duration? dismissAfter, String? details}) {
    return show(AppNotification(
      id: const Uuid().v4(),
      title: title,
      body: body,
      severity: NotificationSeverity.warning,
      dismissAfter: dismissAfter,
      details: details,
    ), countRepeats: true);
  }

  /// [details]: what stands behind it, already the report Copy details
  /// copies (ErrorReport.build: scrubbed).
  String error(String title, {String? body, Duration? dismissAfter, String? details}) {
    return show(AppNotification(
      id: const Uuid().v4(),
      title: title,
      body: body,
      severity: NotificationSeverity.error,
      dismissAfter: dismissAfter,
      details: details,
    ), countRepeats: true);
  }

  /// Dismiss a notification's toast. Keeps the entry in history (so
  /// the user can find it in the bell) but marks it read.
  void dismissToast(String id) {
    _timers.remove(id)?.cancel();
    // A transient notification (e.g. a "Testing…" progress toast) leaves no
    // bell-history trace - dropping its toast drops the entry entirely instead
    // of keeping it as a read row.
    final entry = state.history.firstWhere(
      (n) => n.id == id,
      orElse: () => AppNotification(id: id, title: ''),
    );
    if (entry.transient && entry.title.isNotEmpty) {
      remove(id);
      return;
    }
    if (state.visibleToastIds.contains(id)) {
      final newVisible = {...state.visibleToastIds}..remove(id);
      state = state.copyWith(visibleToastIds: newVisible);
      _markRead(id);
      _drainQueue();
    }
  }

  /// Drop the entry from history entirely (toast + bell row gone).
  void remove(String id) {
    _timers.remove(id)?.cancel();
    _countable.remove(id);
    final newHistory =
        state.history.where((n) => n.id != id).toList(growable: false);
    final newVisible = state.visibleToastIds.contains(id)
        ? ({...state.visibleToastIds}..remove(id))
        : state.visibleToastIds;
    state = state.copyWith(
      history: newHistory,
      visibleToastIds: newVisible,
    );
    _persist();
    _drainQueue();
  }

  /// Mark every entry in history as read. Called by the bell
  /// dropdown when it closes.
  void markAllRead() {
    state = state.copyWith(
      history: [
        for (final n in state.history)
          if (n.isRead) n else n.copyWith(isRead: true),
      ],
    );
    _persist();
  }

  /// Mark a single history entry read (mobile: tapping a notification row).
  void markRead(String id) => _markRead(id);

  /// Mark read every entry matching [test] (mobile: a group's "Mark read"
  /// action, e.g. only Today). One state write regardless of how many match.
  void markReadWhere(bool Function(AppNotification n) test) {
    state = state.copyWith(
      history: [
        for (final n in state.history)
          if (!n.isRead && test(n)) n.copyWith(isRead: true) else n,
      ],
    );
    _persist();
  }

  /// Clear the entire history. Cancels all auto-dismiss timers.
  void clearAll() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    _toastQueue.clear();
    _countable.clear();
    state = const NotificationsState();
    _persist();
  }

  /// Subscribe to "a new notification just appeared as a toast"
  /// events. The overlay uses this to drive its slide-in animation.
  void Function() addOnShowListener(void Function(AppNotification) cb) {
    _onShowListeners.add(cb);
    return () => _onShowListeners.remove(cb);
  }

  // ── Internal ──────────────────────────────────────────────────────

  void _markRead(String id) {
    state = state.copyWith(
      history: [
        for (final n in state.history)
          if (n.id == id && !n.isRead) n.copyWith(isRead: true) else n,
      ],
    );
    _persist();
  }

  void _showToast(AppNotification n) {
    state = state.copyWith(
      visibleToastIds: {...state.visibleToastIds, n.id},
    );
    for (final cb in _onShowListeners) {
      cb(n);
    }

    final dur = n.effectiveDismissDuration;
    if (dur > Duration.zero) {
      _timers[n.id] = Timer(dur, () => dismissToast(n.id));
    }
  }

  void _drainQueue() {
    while (_toastQueue.isNotEmpty &&
        state.visibleToastIds.length < _maxConcurrentToasts) {
      final id = _toastQueue.removeFirst();
      final n = state.history.firstWhere(
        (h) => h.id == id,
        orElse: () => AppNotification(id: id, title: ''),
      );
      if (n.title.isNotEmpty) {
        _showToast(n);
      }
    }
  }
}

/// Single shared instance.
final notificationCenterProvider =
    NotifierProvider<NotificationCenter, NotificationsState>(
  NotificationCenter.new,
);
