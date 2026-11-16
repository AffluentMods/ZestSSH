import 'package:flutter/foundation.dart';

/// Severity drives default visual styling, default auto-dismiss, and
/// whether the bell icon shows an unread badge.
enum NotificationSeverity {
  /// Background event - "Tab closed", "Identity saved". Auto-dismisses
  /// quickly and doesn't show an unread dot.
  info,

  /// Something completed successfully (e.g. "Connected to host"). Same
  /// visual as info but with the brand-success accent.
  success,

  /// User-actionable but non-fatal - "Host key changed", "Password
  /// expires soon". Persists in the history; the bell shows an
  /// unread count.
  warning,

  /// Something broke. Stays on screen until dismissed; the bell
  /// shows an unread count.
  error;

  /// Whether a notice of this kind not yet seen is counted by the bell.
  bool get countsAsUnread => this == warning || this == error;
}

/// In-memory representation of a single notification entry.
@immutable
class AppNotification {
  AppNotification({
    required this.id,
    required this.title,
    this.body,
    this.summary,
    this.severity = NotificationSeverity.info,
    DateTime? createdAt,
    this.actionLabel,
    this.onAction,
    this.isRead = false,
    this.dismissAfter,
    this.transient = false,
    this.details,
    this.repeats = 1,
  }) : createdAt = createdAt ?? DateTime.now();

  /// Stable id - used by the dismiss / mark-read / replace APIs.
  final String id;

  /// Single-line title shown both in the toast and the bell history.
  final String title;

  /// Optional secondary line - supplementary detail shown below the
  /// title in the toast, and as a second line in the history.
  final String? body;

  /// What a toast shows in place of [body], a line each, where [body] says
  /// more than a toast should hold: a line or two to take in at a glance (a
  /// paragraph stood there cut at its sixth line, with Show more). The bell
  /// keeps [body] whole. Kept in memory only, like [onAction].
  final List<String>? summary;

  final NotificationSeverity severity;
  final DateTime createdAt;

  /// Optional action button label (e.g. "Undo"). `null` hides the
  /// button.
  final String? actionLabel;

  /// Callback fired when the action button is tapped.
  final VoidCallback? onAction;

  /// Whether the user has seen this notification in the bell history.
  /// Toasts that appear briefly are also marked read on dismissal.
  final bool isRead;

  /// Auto-dismiss timer override. `null` = use severity default
  /// (info: 4s, success: 4s, warning: 8s, error: never).
  /// `Duration.zero` means "stay until manually dismissed".
  final Duration? dismissAfter;

  /// Transient notifications surface as a toast but leave NO trace in the bell
  /// history - when the toast is dismissed (manually or on its timer) the entry
  /// is removed entirely rather than kept as read. Use for ephemeral progress
  /// like "Testing connection…" that shouldn't clutter the notification list.
  final bool transient;

  /// What stands behind an error, as the text its "Copy details" copies
  /// (ErrorReport.build: scrubbed, in English). Kept in memory only, like
  /// the app's log it ends with: it is never written with the history.
  final String? details;

  /// How many times this was said while it stood on screen: the same notice
  /// said again there is counted on it ([NotificationCenter.show]). 1 for a
  /// notice said once.
  final int repeats;

  /// Serialisable subset for persistence (mobile history survives a restart).
  /// The runtime-only fields are dropped: [onAction] (a closure), [dismissAfter]
  /// (a live timer hint), [details] (nothing of the app's log goes to disk), and
  /// [transient] entries are never persisted at all
  /// (the caller filters them out). A restored notification therefore has no
  /// action callback - its row still marks read and dismisses, it just cannot
  /// deep-link after a restart.
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        if (body != null) 'body': body,
        'severity': severity.index,
        'createdAt': createdAt.toIso8601String(),
        'isRead': isRead,
        if (actionLabel != null) 'actionLabel': actionLabel,
        if (repeats > 1) 'repeats': repeats,
      };

  /// Throws [FormatException] on an unusable row (missing id or unparseable
  /// timestamp) so the loader can drop just that entry instead of re-dating a
  /// corrupt row to now() (which would let it survive the age prune forever).
  /// Numeric fields are read defensively so a String/double never TypeErrors.
  factory AppNotification.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String?;
    if (id == null || id.isEmpty) {
      throw const FormatException('notification missing id');
    }
    final created = DateTime.tryParse(json['createdAt'] as String? ?? '');
    if (created == null) {
      throw const FormatException('notification has unparseable createdAt');
    }
    final sevIndex = (json['severity'] as num?)?.toInt() ?? 0;
    return AppNotification(
      id: id,
      title: json['title'] as String? ?? '',
      body: json['body'] as String?,
      severity: sevIndex >= 0 && sevIndex < NotificationSeverity.values.length
          ? NotificationSeverity.values[sevIndex]
          : NotificationSeverity.info,
      createdAt: created,
      actionLabel: json['actionLabel'] as String?,
      isRead: json['isRead'] as bool? ?? false,
      repeats: _countOf(json['repeats']),
    );
  }

  /// A count as it was saved: 1 for none, or for one that is no count.
  static int _countOf(Object? saved) {
    final n = saved is num ? saved.toInt() : 1;
    return n < 1 ? 1 : n;
  }

  AppNotification copyWith({
    String? title,
    String? body,
    List<String>? summary,
    NotificationSeverity? severity,
    bool? isRead,
    String? actionLabel,
    VoidCallback? onAction,
    Duration? dismissAfter,
    bool? transient,
    String? details,
    DateTime? createdAt,
    int? repeats,
  }) {
    return AppNotification(
      id: id,
      title: title ?? this.title,
      body: body ?? this.body,
      summary: summary ?? this.summary,
      severity: severity ?? this.severity,
      createdAt: createdAt ?? this.createdAt,
      actionLabel: actionLabel ?? this.actionLabel,
      onAction: onAction ?? this.onAction,
      isRead: isRead ?? this.isRead,
      dismissAfter: dismissAfter ?? this.dismissAfter,
      transient: transient ?? this.transient,
      details: details ?? this.details,
      repeats: repeats ?? this.repeats,
    );
  }

  /// Severity-driven default auto-dismiss duration. Errors stay until
  /// dismissed so the user can read the full message.
  ///
  /// One that goes by itself stays long enough to be read (the 4.0
  /// accessibility pass, WCAG's time limits): two seconds and a little for
  /// each character, up to 15; and at least 10 where it has something to
  /// press (its action, Copy details), as long as it takes to find it.
  Duration get effectiveDismissDuration {
    final asked = dismissAfter ?? _bySeverity;
    if (asked == Duration.zero) return asked;
    final characters = title.length + (body?.length ?? 0);
    var least = Duration(milliseconds: (2000 + 60 * characters).clamp(0, 15000));
    if ((actionLabel != null || details != null) && least < kNoticeWithActionStays) least = kNoticeWithActionStays;
    return asked < least ? least : asked;
  }

  Duration get _bySeverity {
    switch (severity) {
      case NotificationSeverity.info:
      case NotificationSeverity.success:
        return const Duration(seconds: 4);
      case NotificationSeverity.warning:
        return const Duration(seconds: 8);
      case NotificationSeverity.error:
        return Duration.zero; // sticky
    }
  }
}

/// The least a notice with something to press stays before it goes by
/// itself.
const Duration kNoticeWithActionStays = Duration(seconds: 10);
