import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';
import 'package:zestssh/features/tickets/ticket_token.dart';

/// What kind of report the user is sending (help/feedback/support spec,
/// section 3). Support is not a report: it goes to Discord or email.
enum FeedbackType {
  bug('bug'),
  suggestion('suggestion');

  const FeedbackType(this.wire);

  /// The value on the wire and in the Discord post.
  final String wire;

  static FeedbackType fromWire(String v) => FeedbackType.values
      .firstWhere((t) => t.wire == v, orElse: () => FeedbackType.bug);
}

/// The six facts that are attached to every report, and nothing else: no
/// logs, no host list, no config, no install id (spec 3a). Shown to the user
/// verbatim in the "what will be sent" preview.
class FeedbackContext {
  const FeedbackContext({
    required this.appVersion,
    required this.build,
    required this.platform,
    required this.osVersion,
    required this.locale,
    required this.tier,
  });

  final String appVersion;
  final int build;
  final String platform;
  final String osVersion;
  final String locale;
  final String tier;

  Map<String, Object> toJson() => {
        'app_version': appVersion,
        'build': build,
        'platform': platform,
        'os_version': osVersion,
        'locale': locale,
        'tier': tier,
      };

  factory FeedbackContext.fromJson(Map<String, dynamic> j) => FeedbackContext(
        appVersion: '${j['app_version'] ?? ''}',
        build: (j['build'] is num)
            ? (j['build'] as num).toInt()
            : int.tryParse('${j['build'] ?? ''}') ?? 0,
        platform: '${j['platform'] ?? ''}',
        osVersion: '${j['os_version'] ?? ''}',
        locale: '${j['locale'] ?? ''}',
        tier: '${j['tier'] ?? ''}',
      );
}

/// Hard caps, enforced on the client (with a visible counter) and again on
/// the server (which truncates with a marker). The title cap is Discord's
/// thread-name cap.
class FeedbackLimits {
  FeedbackLimits._();

  static const int titleMax = 100;
  static const int bodyMax = 4000;
  static const int extraMax = 2000;
  static const int contactMax = 64;

  /// PNG bytes before base64. Keeps a report well under the server's parser
  /// limit even on a 4K display.
  static const int screenshotMaxBytes = 1500 * 1024;
}

/// An optional way to follow up, typed by hand (spec 1). Only Discord today.
class FeedbackContact {
  const FeedbackContact.discord(this.handle);

  final String handle;

  Map<String, String> toJson() => {'kind': 'discord', 'handle': handle};

  static FeedbackContact? fromJson(Object? raw) {
    if (raw is Map && raw['kind'] == 'discord' && raw['handle'] is String) {
      final h = (raw['handle'] as String).trim();
      return h.isEmpty ? null : FeedbackContact.discord(h);
    }
    return null;
  }
}

/// Optional category on a suggestion: the public tags of the suggestions
/// forum. Sent as a value the bot maps to a tag, never as a tag id.
enum FeedbackCategory {
  uiUx('ui_ux', 'UI/UX'),
  newFeature('new_feature', 'New feature'),
  qualityOfLife('quality_of_life', 'Quality of life');

  const FeedbackCategory(this.wire, this.plainLabel);

  /// The value on the wire.
  final String wire;

  /// English label for the clipboard fallback (the form uses l10n).
  final String plainLabel;

  static FeedbackCategory? fromWire(Object? v) {
    for (final c in values) {
      if (c.wire == v) return c;
    }
    return null;
  }
}

const _uuid = Uuid();

/// One report, exactly as it is sent (spec 3a). [toJson] IS the payload; the
/// preview in the form renders this same object so what the user sees is
/// what leaves the device.
class FeedbackReport {
  FeedbackReport({
    required this.type,
    this.title = '',
    required this.body,
    this.expected,
    this.steps,
    this.why,
    this.category,
    required this.context,
    this.contact,
    this.screenshotPng,
    this.screenshotRedacted = true,
    this.diagnostics,
    String? nonce,
    String? ticketToken,
    DateTime? createdAt,
  })  : nonce = nonce ?? _uuid.v4(),
        ticketToken = TicketToken.isValid(ticketToken)
            ? ticketToken!
            : TicketToken.generate(),
        createdAt = createdAt ?? DateTime.now();

  final FeedbackType type;

  /// Optional one-liner; the Discord thread name. Derived from the body when
  /// left empty.
  final String title;
  final String body;

  /// Bug reports: what the user expected, and steps to reproduce.
  final String? expected;
  final String? steps;

  /// Suggestions: why, and an optional category.
  final String? why;
  final FeedbackCategory? category;
  final FeedbackContext context;

  /// A typed Discord handle when the user opted out of anonymity, else null.
  /// Never prefilled from the account.
  final FeedbackContact? contact;

  /// Optional PNG, redacted unless the user unchecked that.
  final Uint8List? screenshotPng;
  final bool screenshotRedacted;

  /// What "Include diagnostics" adds (3.4): the app's version, the system and
  /// the last lines of its log, with names, addresses and secrets taken out
  /// (supportDiagnostics). Kept by support with the ticket; like the
  /// screenshot, never in the public post.
  final String? diagnostics;

  /// Random per report (uuid), so a retry of the same report is deduplicated
  /// by the server instead of posted twice. Not an install id.
  final String nonce;

  /// The key to the ticket this report becomes (see [TicketToken]): random
  /// per report, kept on this device, and what lets the person read the
  /// staff's answer here later. Not an account and not an install id. A
  /// retry of the same report carries the same one.
  final String ticketToken;
  final DateTime createdAt;

  bool get isAnonymous => contact == null;

  /// The Discord thread name: the title, else the first line of the body,
  /// capped at Discord's 100 characters.
  String get threadTitle {
    final t = title.trim();
    final source = t.isNotEmpty ? t : body.trim().split('\n').first.trim();
    if (source.length <= FeedbackLimits.titleMax) return source;
    return '${source.substring(0, FeedbackLimits.titleMax - 1)}…';
  }

  static String? _opt(String? v) =>
      v == null || v.trim().isEmpty ? null : v.trim();

  Map<String, dynamic> toJson({bool includeScreenshot = true}) => {
        'type': type.wire,
        'title': threadTitle,
        'body': body.trim(),
        if (_opt(expected) != null) 'expected': _opt(expected),
        if (_opt(steps) != null) 'steps': _opt(steps),
        if (_opt(why) != null) 'why': _opt(why),
        if (type == FeedbackType.suggestion && category != null)
          'category': category!.wire,
        'context': context.toJson(),
        'contact': contact?.toJson(),
        'screenshot': includeScreenshot && screenshotPng != null
            ? base64Encode(screenshotPng!)
            : null,
        if (screenshotPng != null) 'screenshot_redacted': screenshotRedacted,
        if (_opt(diagnostics) != null) 'diagnostics': diagnostics,
        'nonce': nonce,
        'ticket_token': ticketToken,
      };

  factory FeedbackReport.fromJson(Map<String, dynamic> j) => FeedbackReport(
        type: FeedbackType.fromWire('${j['type'] ?? 'bug'}'),
        title: '${j['title'] ?? ''}',
        body: '${j['body'] ?? ''}',
        expected: j['expected'] as String?,
        steps: j['steps'] as String?,
        why: j['why'] as String?,
        category: FeedbackCategory.fromWire(j['category']),
        context: FeedbackContext.fromJson(
            (j['context'] as Map?)?.cast<String, dynamic>() ?? const {}),
        contact: FeedbackContact.fromJson(j['contact']),
        screenshotPng: j['screenshot'] is String
            ? base64Decode(j['screenshot'] as String)
            : null,
        screenshotRedacted: j['screenshot_redacted'] != false,
        diagnostics: j['diagnostics'] is String ? j['diagnostics'] as String : null,
        nonce: j['nonce'] as String?,
        ticketToken:
            j['ticket_token'] is String ? j['ticket_token'] as String : null,
        createdAt: j['createdAt'] is String
            ? DateTime.tryParse(j['createdAt'] as String)
            : null,
      );

  /// The clipboard fallback (spec 3b): the whole report as readable text so
  /// the user can paste it into Discord themselves. The screenshot is not
  /// representable as text and is mentioned instead.
  String toClipboardText() {
    final b = StringBuffer()
      ..writeln('ZestSSH ${type.wire} report')
      ..writeln('Title: $threadTitle')
      ..writeln()
      ..writeln(body.trim());
    if (_opt(expected) != null) {
      b
        ..writeln()
        ..writeln('Expected: ${_opt(expected)}');
    }
    if (_opt(steps) != null) {
      b
        ..writeln()
        ..writeln('Steps: ${_opt(steps)}');
    }
    if (_opt(why) != null) {
      b
        ..writeln()
        ..writeln('Why: ${_opt(why)}');
    }
    if (type == FeedbackType.suggestion && category != null) {
      b
        ..writeln()
        ..writeln('Category: ${category!.plainLabel}');
    }
    b
      ..writeln()
      ..writeln('App ${context.appVersion} (${context.build}) on '
          '${context.platform} ${context.osVersion}, ${context.locale}, '
          '${context.tier}');
    if (contact != null) b.writeln('Discord: ${contact!.handle}');
    if (screenshotPng != null) {
      b.writeln(screenshotRedacted
          ? '(a redacted screenshot was attached)'
          : '(a screenshot was attached)');
    }
    return b.toString();
  }

  /// A JSON rendering of the exact payload for the "see exactly what will be
  /// sent" preview. The screenshot is summarised as its size so the preview
  /// stays readable, and the ticket key is named, not shown: it is a secret,
  /// and a preview is the kind of thing that gets pasted into a chat.
  String toPreviewJson() {
    final j = toJson(includeScreenshot: false);
    j['ticket_token'] = TicketToken.preview;
    if (screenshotPng != null) {
      j['screenshot'] = '<png, ${(screenshotPng!.length / 1024).round()} KB>';
    }
    return const JsonEncoder.withIndent('  ').convert(j);
  }
}
