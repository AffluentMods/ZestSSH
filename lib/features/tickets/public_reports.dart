import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/tickets/ticket_models.dart';
import 'package:zestssh/features/tickets/ticket_service.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/account_bearer.dart';
import 'package:zestssh/services/pinned_http_client.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';

/// Where a public report stands, as the lists say it (ZestSSH Cloud's
/// lib/tickets.js, STATES). A report with none is new: "Under review".
enum ReportState {
  planned('planned'),
  investigating('investigating'),
  inProgress('in_progress'),
  fixed('fixed'),
  shipped('shipped');

  const ReportState(this.wire);
  final String wire;

  static ReportState? fromWire(Object? v) {
    for (final s in values) {
      if (s.wire == v) return s;
    }
    return null;
  }
}

/// Everyone's bug report or idea, as the public lists show it: nothing that
/// says who sent it (public with names removed).
class PublicReport {
  const PublicReport({
    required this.id,
    required this.type,
    required this.title,
    this.number,
    this.body = '',
    this.state,
    this.stateVersion,
    this.votes = 0,
    this.comments = 0,
    this.closed = false,
    this.discordUrl,
    required this.createdAt,
    this.closedAt,
  });

  /// The id the lists show: never a ticket's own id.
  final String id;
  final TicketType type;
  final int? number;
  final String title;
  final String body;
  final ReportState? state;

  /// The version a fix or an idea came in ("3.3.1"), when staff said one.
  final String? stateVersion;
  final int votes;
  final int comments;
  final bool closed;
  final String? discordUrl;
  final DateTime createdAt;
  final DateTime? closedAt;

  static final RegExp _idShape = RegExp(r'^[0-9a-f]{12}$');
  static final RegExp _versionShape = RegExp(r'^[0-9A-Za-z.+-]{1,20}$');

  PublicReport withVotes(int n) => PublicReport(
        id: id,
        type: type,
        number: number,
        title: title,
        body: body,
        state: state,
        stateVersion: stateVersion,
        votes: n < 0 ? 0 : n,
        comments: comments,
        closed: closed,
        discordUrl: discordUrl,
        createdAt: createdAt,
        closedAt: closedAt,
      );

  /// Null when [raw] is not a report the app can show.
  static PublicReport? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final type = raw['type'];
    final title = raw['title'];
    final created = DateTime.tryParse('${raw['created_at'] ?? ''}');
    if (id is! String || !_idShape.hasMatch(id)) return null;
    if (type != 'bug' && type != 'suggestion') return null;
    if (title is! String || title.trim().isEmpty || created == null) return null;
    final number = raw['number'];
    final body = raw['body'];
    final version = raw['state_version'];
    final votes = raw['votes'];
    final comments = raw['comments'];
    return PublicReport(
      id: id,
      type: TicketType.fromWire(type),
      number: number is int && number > 0 && number <= kMaxTicketNumber ? number : null,
      title: _cut(title.trim(), 200),
      body: body is String ? _cut(body.trim(), 600) : '',
      state: ReportState.fromWire(raw['state']),
      stateVersion: version is String && _versionShape.hasMatch(version) ? version : null,
      votes: votes is int && votes >= 0 ? votes : 0,
      comments: comments is int && comments >= 0 ? comments : 0,
      closed: raw['closed'] == true,
      discordUrl: TicketService.discordLinkOf(raw['discord_url']),
      createdAt: created,
      closedAt: DateTime.tryParse('${raw['closed_at'] ?? ''}'),
    );
  }

  static String _cut(String s, int max) {
    final runes = s.runes;
    return runes.length <= max ? s : String.fromCharCodes(runes.take(max));
  }
}

/// How a +1 went.
enum VoteOutcome {
  done,

  /// The account may not vote.
  blocked,

  /// The report is not listed any more.
  notListed,

  /// The report is closed.
  closed,

  /// A limit fired.
  rateLimited,

  /// The server could not be reached, or answered something else.
  failed,
}

class VoteResult {
  const VoteResult(this.outcome, {this.votes, this.voted});
  final VoteOutcome outcome;
  final int? votes;
  final bool? voted;
}

/// Which list: Known issues (bugs) or Ideas, sorted by +1s or newest, or only
/// those in one state.
class ReportQuery {
  const ReportQuery(this.type, {this.newest = false, this.state});
  final TicketType type;
  final bool newest;
  final ReportState? state;

  @override
  bool operator ==(Object other) =>
      other is ReportQuery && other.type == type && other.newest == newest && other.state == state;

  @override
  int get hashCode => Object.hash(type, newest, state);
}

/// The header a +1 carries this device's guest id in (ZestSSH Cloud's
/// routes/reports.js).
const kVoteDeviceHeader = 'X-ZestSSH-Device';

/// Where this install keeps the id it gives with a +1: a device key (every
/// profile here shares it), kept by "Reset all settings" so a reset does not
/// make a second voter of the same device (SettingsService).
const kReportVoteDeviceKey = 'report_vote_device_id';

/// Where this install keeps which reports it +1'd with nobody signed in: the
/// server is never asked (that would send the id as the lists are read).
const kReportVoteDeviceVotesKey = 'report_vote_device_votes';
const _guestVotesKept = 500;

final RegExp _deviceIdShape = RegExp(r'^[A-Za-z0-9_-]{16,128}$');

/// The id this install gives with a +1 (3.4: anyone may +1, once per account,
/// or once per device for someone not signed in).
/// Made once, 32 random bytes in base64url, and kept in [prefs]: it says
/// nothing of the person, and the server keeps only its hash.
String reportVoteDeviceId(SharedPreferences prefs, {Random? random}) {
  final kept = prefs.getString(kReportVoteDeviceKey);
  if (kept != null && _deviceIdShape.hasMatch(kept)) return kept;
  final r = random ?? Random.secure();
  final id = base64Url.encode([for (var i = 0; i < 32; i++) r.nextInt(256)]).replaceAll('=', '');
  unawaited(prefs.setString(kReportVoteDeviceKey, id));
  return id;
}

/// The reports this install +1'd with nobody signed in, as it kept them.
Set<String> reportGuestVotes(SharedPreferences prefs) => {
      for (final id in prefs.getStringList(kReportVoteDeviceVotesKey) ?? const <String>[])
        if (RegExp(r'^[0-9a-f]{12}$').hasMatch(id)) id,
    };

/// Keeps (or forgets, [on] false) this install's guest +1 on [id]; the newest
/// [_guestVotesKept] are kept.
Future<void> rememberReportGuestVote(SharedPreferences prefs, String id, bool on) async {
  final ids = [...reportGuestVotes(prefs)]..remove(id);
  if (on) ids.add(id);
  await prefs.setStringList(
    kReportVoteDeviceVotesKey,
    ids.length > _guestVotesKept ? ids.sublist(ids.length - _guestVotesKept) : ids,
  );
}

/// Everyone's bug reports and ideas, and +1 (ZestSSH Cloud's
/// routes/reports.js). The lists and the duplicate search need no account and
/// carry none. A +1 carries the account when someone is signed in, and only
/// then; with nobody signed in it carries this device's guest id instead, and
/// which ones it gave are kept on the device, so the id goes with a +1 and
/// with nothing else, and is never sent beside an account (the 3.4 security
/// review). The server keeps one per account, or one per device and report for
/// someone not signed in, and the total it answers counts the +1s pressed in
/// Discord too.
///
/// Asked only when the Support Hub or the Help panel shows a list, or as a
/// title is typed in a new report: never in the background.
class PublicReportsService {
  PublicReportsService({
    http.Client? client,
    Future<String?> Function()? bearer,
    Future<String?> Function()? deviceId,
    Future<Set<String>> Function()? guestVotes,
    Future<void> Function(String id, bool on)? rememberGuestVote,
    String? baseUrl,
  })  : _client = client,
        _bearer = bearer,
        _deviceId = deviceId,
        _guestVotes = guestVotes,
        _rememberGuestVote = rememberGuestVote,
        base = baseUrl ?? TicketService.defaultBase;

  final http.Client? _client;
  final Future<String?> Function()? _bearer;
  final Future<String?> Function()? _deviceId;
  final Future<Set<String>> Function()? _guestVotes;
  final Future<void> Function(String id, bool on)? _rememberGuestVote;
  final String base;

  static const Duration _timeout = Duration(seconds: 15);

  http.Client get _http => _client ?? PinnedHttpClient.client;

  /// A list. Throws when the server could not be reached or answered no list.
  Future<List<PublicReport>> list(ReportQuery q) async {
    final uri = Uri.parse('$base/reports').replace(queryParameters: {
      'type': q.type.wire,
      'sort': q.newest ? 'new' : 'top',
      if (q.state != null) 'state': q.state!.wire,
    });
    return _reports(await _http.get(uri).timeout(_timeout));
  }

  /// The listed reports whose titles look like [text]; empty when nothing
  /// was typed. Throws when the server could not be reached.
  Future<List<PublicReport>> similar(String text, TicketType type) async {
    final words = text.trim();
    if (words.length < 3) return const [];
    final uri = Uri.parse('$base/reports/similar').replace(queryParameters: {
      'q': words.length > 200 ? words.substring(0, 200) : words,
      'type': type.wire,
    });
    return _reports(await _http.get(uri).timeout(_timeout));
  }

  List<PublicReport> _reports(http.Response resp) {
    if (resp.statusCode != 200) throw StateError('HTTP ${resp.statusCode}');
    final j = jsonDecode(resp.body);
    final list = j is Map ? j['reports'] : null;
    if (list is! List) throw const FormatException('no reports');
    return [for (final r in list) ?PublicReport.fromJson(r)];
  }

  /// The account's sign-in, or null when nobody is signed in.
  Future<Map<String, String>?> _account() async {
    final bearer = await _bearer?.call();
    if (bearer == null || bearer.isEmpty) return null;
    return {'Authorization': 'Bearer $bearer', ...DeviceSessionHeader.headers};
  }

  /// Who a +1 is from: the account when someone is signed in, else this
  /// device's guest id (never both); null when neither can be said.
  Future<({Map<String, String> headers, bool guest})?> _voter() async {
    final account = await _account();
    if (account != null) return (headers: account, guest: false);
    try {
      final id = await _deviceId?.call();
      if (id != null && _deviceIdShape.hasMatch(id)) return (headers: {kVoteDeviceHeader: id}, guest: true);
    } catch (e) {
      AppLogger.warning('Vote device id not read: ${errorKind(e)}');
    }
    return null;
  }

  /// The ids of the listed reports this person +1'd: the account's, asked of
  /// the server; with nobody signed in, the ones this device kept (the server
  /// is not asked). Empty when the server cannot be reached.
  Future<Set<String>> myVotes() async {
    final headers = await _account();
    if (headers == null) return {...?await _guestVotes?.call()};
    try {
      final resp = await _http.get(Uri.parse('$base/reports/votes'), headers: headers).timeout(_timeout);
      if (resp.statusCode != 200) return const {};
      final j = jsonDecode(resp.body);
      final ids = j is Map ? j['voted'] : null;
      return {
        if (ids is List)
          for (final id in ids)
            if (id is String) id,
      };
    } catch (e) {
      AppLogger.warning('Report votes not read: ${errorKind(e)}');
      return const {};
    }
  }

  /// +1 on [id], or takes it back ([on] false). Never throws.
  Future<VoteResult> vote(String id, {required bool on}) async {
    final voter = await _voter();
    if (voter == null) return const VoteResult(VoteOutcome.failed);
    final headers = voter.headers;
    try {
      final uri = Uri.parse('$base/reports/$id/vote');
      final resp = await (on ? _http.post(uri, headers: headers) : _http.delete(uri, headers: headers)).timeout(_timeout);
      Map? j;
      try {
        final d = jsonDecode(resp.body);
        if (d is Map) j = d;
      } catch (_) {
        j = null;
      }
      final code = j?['code'];
      if (resp.statusCode == 200) {
        final votes = j?['votes'];
        final voted = j?['voted'] == true;
        if (voter.guest) await _rememberGuestVote?.call(id, voted);
        return VoteResult(VoteOutcome.done, votes: votes is int ? votes : null, voted: voted);
      }
      return VoteResult(switch (resp.statusCode) {
        403 when code == 'blocked' => VoteOutcome.blocked,
        404 => VoteOutcome.notListed,
        409 => VoteOutcome.closed,
        429 || 503 => VoteOutcome.rateLimited,
        _ => VoteOutcome.failed,
      });
    } catch (e) {
      AppLogger.warning('Report vote not delivered: ${errorKind(e)}');
      return const VoteResult(VoteOutcome.failed);
    }
  }
}

final publicReportsServiceProvider = Provider<PublicReportsService>(
  (ref) => PublicReportsService(
    bearer: accountBearer,
    deviceId: () async => reportVoteDeviceId(ref.read(sharedPreferencesProvider)),
    guestVotes: () async => reportGuestVotes(ref.read(sharedPreferencesProvider)),
    rememberGuestVote: (id, on) => rememberReportGuestVote(ref.read(sharedPreferencesProvider), id, on),
  ),
);

/// One list, read when something shows it. Errors are the screen's to say.
final publicReportsProvider = FutureProvider.autoDispose.family<List<PublicReport>, ReportQuery>((ref, q) {
  return ref.watch(publicReportsServiceProvider).list(q);
});

/// What this device knows of this person's +1s (the account's, and this
/// device's when nobody is signed in): the ids they +1'd and the counts a +1
/// here changed, laid over the lists so a click shows at once.
class ReportVotes {
  const ReportVotes({this.voted = const {}, this.counts = const {}, this.loaded = false});

  final Set<String> voted;

  /// The count the server answered a +1 here with, by id.
  final Map<String, int> counts;

  /// This person's +1s have been read from the server.
  final bool loaded;

  bool hasVoted(String id) => voted.contains(id);

  /// [r] with the count a +1 here last answered.
  PublicReport over(PublicReport r) => counts.containsKey(r.id) ? r.withVotes(counts[r.id]!) : r;
}

class ReportVotesNotifier extends StateNotifier<ReportVotes> {
  ReportVotesNotifier(this._service) : super(const ReportVotes());

  final PublicReportsService _service;
  final Set<String> _busy = {};

  /// The reports a +1 here went through for while a read of this person's
  /// +1s was on its way: that read may not know of it yet.
  final Set<String> _changedWhileReading = {};
  int _reading = 0;

  /// Reads this person's +1s, once per showing. The counts a +1 here answered
  /// give way then to the list read with them, which has the latest total
  /// (+1s given since by others, in Discord too); a +1 given while the read
  /// was on its way keeps what it answered.
  Future<void> load() async {
    if (_reading++ == 0) _changedWhileReading.clear();
    final Set<String> ids;
    try {
      ids = await _service.myVotes();
    } finally {
      _reading--;
    }
    if (!mounted) return;
    final voted = {...ids};
    final counts = <String, int>{};
    for (final id in _changedWhileReading) {
      if (state.voted.contains(id)) {
        voted.add(id);
      } else {
        voted.remove(id);
      }
      if (state.counts[id] case final n?) counts[id] = n;
    }
    state = ReportVotes(voted: voted, counts: counts, loaded: true);
  }

  /// +1 [r] or takes it back. Returns how it went; the state shows the new
  /// count at once where it went through.
  Future<VoteResult> toggle(PublicReport r) async {
    if (_busy.contains(r.id)) return const VoteResult(VoteOutcome.failed);
    _busy.add(r.id);
    try {
      final on = !state.hasVoted(r.id);
      final result = await _service.vote(r.id, on: on);
      if (!mounted) return result;
      if (result.outcome == VoteOutcome.done) {
        if (_reading > 0) _changedWhileReading.add(r.id);
        final voted = {...state.voted};
        if (result.voted ?? on) {
          voted.add(r.id);
        } else {
          voted.remove(r.id);
        }
        state = ReportVotes(
          voted: voted,
          counts: {...state.counts, if (result.votes != null) r.id: result.votes!},
          loaded: state.loaded,
        );
      }
      return result;
    } finally {
      _busy.remove(r.id);
    }
  }
}

final reportVotesProvider =
    StateNotifierProvider<ReportVotesNotifier, ReportVotes>((ref) => ReportVotesNotifier(ref.watch(publicReportsServiceProvider)));
