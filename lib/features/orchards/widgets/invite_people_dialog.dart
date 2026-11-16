import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:io' show File;
import 'dart:math' show max;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:zestssh/features/orchards/billing/orchard_billing.dart' show OrchardSeats;
import 'package:zestssh/features/orchards/crypto/join_code_crypto.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/team/team_seats.dart' show billingOnThisDeviceProvider;
import 'package:zestssh/features/orchards/team/team_seats_sheet.dart' show openSeatsSheet;
import 'package:zestssh/features/orchards/widgets/team_admin_ui.dart' show teamButton, TeamButtonKind;
import 'package:zestssh/features/orchards/widgets/member_dialogs.dart';
import 'package:zestssh/features/orchards/widgets/orchard_invites.dart'
    show inviteErrorMessage, inviteSeatsNeededOf, orchardInvitesVersionProvider;
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/settings_providers.dart' show recordingModeProvider;
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/recording_reveal_gate.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/platform_utils.dart';
import 'package:zestssh/utils/secret_clipboard.dart';
import 'package:zestssh/l10n/time_text.dart';

// "Invite to <team>": one dialog,
// two ways. Email: one or more addresses, each checked by comparing
// fingerprints once they accept. Code or QR: a one-time code made on this
// device, shown as text, a link and a QR code; it checks both sides' keys,
// so nobody compares fingerprints, and ZestSSH Cloud never sees it
// (crypto/join_code_crypto.dart). Both offer the same: a role below this
// account's own, vaults at a level above the role's where this account may
// hand that on, and an end date. Either way, nobody is in until someone who
// may invite lets them in.

/// The two ways to invite.
enum InviteWay { email, code }

/// How long a code may wait: an hour, a day, a week, 30 days (seconds).
const List<int> kInviteCodeExpiries = [3600, 86400, 604800, 2592000];

/// How many people may use a code: one, or a team code for more.
///
const List<int> kInviteCodeUses = [1, 5, 10, 25];

/// What an invitation offers.
class InviteOffer {
  const InviteOffer({required this.role, this.extra = const {}, this.endsAt});

  /// 'admin' or the id of a role the owners made.
  final String role;

  /// Vaults offered above the role's own level, at that level.
  final Map<String, CrateLevel> extra;

  /// When the access ends, in seconds since the epoch; null for never.
  final int? endsAt;

  Map<String, Set<String>> get grants =>
      role == FixedRoles.admin ? const {} : {for (final e in extra.entries) e.key: levelSwitches(e.value)};

  InviteOffer copyWith({String? role, Map<String, CrateLevel>? extra, int? Function()? endsAt}) => InviteOffer(
      role: role ?? this.role, extra: extra ?? this.extra, endsAt: endsAt == null ? this.endsAt : endsAt());

  bool sameAs(InviteOffer o) =>
      o.role == role &&
      o.endsAt == endsAt &&
      o.extra.length == extra.length &&
      o.extra.entries.every((e) => extra[e.key] == e.value);
}

/// What the dialog closed with: the addresses invited (and whether an email
/// went to each), or a code made.
class InviteDialogResult {
  const InviteDialogResult({this.sent = const [], this.emailed = false, this.code = false});

  final List<String> sent;
  final bool emailed;
  final bool code;
}

/// The roles [orchard]'s account may offer: those below its own rank, and
/// Admin for an owner.
List<({String id, String label})> offerableRoles(
    OrchardSummary orchard, List<OrchardRoleView> roles, AppLocalizations l10n) {
  final mine = switch (orchard.role) {
    FixedRoles.owner => kOwnerRank,
    FixedRoles.admin => kAdminRank,
    final id => roles.where((r) => r.id == id).firstOrNull?.rank ?? 0,
  };
  return [
    for (final r in roles)
      if (r.rank < mine) (id: r.id, label: r.name ?? l10n.orchardRoleMember),
    if (orchard.isOwner) (id: FixedRoles.admin, label: l10n.orchardRoleAdmin),
  ];
}

/// The levels this account may hand on in [crate]: those whose switches it
/// has there itself (the record's rule, which the server holds to too).
/// Owners-only vaults are never offered.
List<CrateLevel> handableLevels(CrateSummary crate) => crate.ownersOnly
    ? const []
    : [
        for (final l in CrateLevel.values)
          if (levelSwitches(l)
              .where((s) => !CrateSwitches.capped.contains(s) || crate.allow.contains(s))
              .every(crate.switches.contains))
            l,
      ];

/// The level [role] gives in [crateId] by itself; null for none. [admin]
/// is the Admin role as an owner changed it ([OrchardSummary.adminRole];
/// null: Manage in every vault that is not owners-only).
CrateLevel? roleLevelIn(String role, String crateId, List<OrchardRoleView> roles, {required RecordAdminRole? admin}) {
  if (role == FixedRoles.owner) return CrateLevel.manage;
  if (role == FixedRoles.admin) {
    final s = adminSwitches(admin, crateId: crateId, ownersOnly: false);
    return s.isEmpty ? null : levelOf(s);
  }
  final switches = roles.where((r) => r.id == role).firstOrNull?.crates[crateId];
  return switches == null ? null : levelOf(switches);
}

/// Each vault [offer] opens and at what level, the role's or above.
List<({CrateSummary crate, CrateLevel level})> offeredVaults(
    InviteOffer offer, OrchardSummary orchard, List<OrchardRoleView> roles) {
  return [
    for (final c in orchard.crates)
      if (!c.ownersOnly)
        if (_effective(offer, c.id, roles, orchard.adminRole) case final level?) (crate: c, level: level),
  ];
}

CrateLevel? _effective(InviteOffer offer, String crateId, List<OrchardRoleView> roles, RecordAdminRole? admin) {
  final own = roleLevelIn(offer.role, crateId, roles, admin: admin);
  final extra = offer.extra[crateId];
  if (own == null) return extra;
  if (extra == null) return own;
  return extra.index > own.index ? extra : own;
}

/// "Invite to" a team. Returns once something was sent or made (true), or
/// the dialog was closed (false). [way] is the choice it opens on;
/// [replacing], an invitation to an address a code is sent instead of: the
/// dialog then makes a code with its offer.
Future<bool> showInvitePeople(BuildContext context, WidgetRef ref, OrchardSummary orchard,
    {InviteWay way = InviteWay.email, OrchardInvite? replacing}) async {
  final l10n = AppLocalizations.of(context)!;
  final result = await showZestModal<InviteDialogResult>(
    context: context,
    size: ZestModalSize.large,
    child: InvitePeopleDialog(orchard: orchard, way: replacing != null ? InviteWay.code : way, replacing: replacing),
  );
  if (result == null || !context.mounted) return false;
  ref.read(orchardInvitesVersionProvider.notifier).state++;
  if (result.sent.length == 1) {
    final email = result.sent.single;
    showTopSnackBar(context, result.emailed ? l10n.orchardInviteSent(email) : l10n.orchardInviteSaved(email),
        isSuccess: true);
  } else if (result.sent.length > 1) {
    showTopSnackBar(context, l10n.inviteSentSeveral, isSuccess: true);
  }
  return true;
}

class InvitePeopleDialog extends ConsumerStatefulWidget {
  const InvitePeopleDialog({super.key, required this.orchard, this.way = InviteWay.email, this.replacing});

  final OrchardSummary orchard;
  final InviteWay way;
  final OrchardInvite? replacing;

  @override
  ConsumerState<InvitePeopleDialog> createState() => _InvitePeopleDialogState();
}

/// The text of a file of addresses the person picks (a CSV, or any text),
/// at most 1 MB; null when none was picked. Tests put their own here.
final inviteAddressFileProvider = Provider<Future<String?> Function()>((ref) => () async {
      final picked = await FilePicker.platform.pickFiles(type: FileType.any);
      final path = picked?.files.singleOrNull?.path;
      if (path == null) return null;
      final bytes = <int>[];
      await for (final chunk in File(path).openRead(0, 1024 * 1024)) {
        bytes.addAll(chunk);
      }
      return utf8.decode(bytes, allowMalformed: true);
    });

/// Every address in [text] (a CSV, a column copied from a sheet, a list
/// in any shape), lower case, in order.
List<String> addressesIn(String text) => [
      for (final m in RegExp(r"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+")
          .allMatches(text))
        m.group(0)!.toLowerCase(),
    ];

final _emailShape = RegExp(
    r"^[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$");

class _InvitePeopleDialogState extends ConsumerState<InvitePeopleDialog> {
  late InviteWay _way = widget.way;
  InviteOffer? _offer;

  // ── Email ──
  final _email = TextEditingController();
  final _emails = <String>[];

  /// Addresses given more than once (each sent once), and what was given
  /// that is no address (left out): both said in the check list.
  ///
  final _twice = <String>{};
  final _bad = <String>[];
  String? _error;
  bool _busy = false;
  int? _seatsNeeded;

  // ── Code ──
  MadeInviteCode? _made;
  bool _making = false;
  String? _codeError;
  int? _codeSeatsNeeded;
  int _expiresIn = kInviteCodeExpiries.first;
  int _usesMax = 1;
  DateTime? _expiresAt;
  bool _remade = false;
  OrchardInvite? _usedBy;
  Timer? _watch;

  /// The code is kept: copied, or on screen [_keepAfter] (long enough to
  /// scan or photograph). One closed sooner is withdrawn at once and never
  /// listed under Invited (before, opening the dialog
  /// made a code, and a code each time).
  bool _kept = false;
  Timer? _keepTimer;
  static const _keepAfter = Duration(seconds: 3);

  /// Read while the dialog lives, to withdraw a code not kept as it goes.
  OrchardService? _service;

  /// The offer replaced a code that was made, before the new one is.
  bool get _cancelling => _making && _made != null;

  @override
  void initState() {
    super.initState();
    _email.addListener(_typed);
    final r = widget.replacing;
    if (r != null) {
      _offer = InviteOffer(
        role: r.role,
        extra: {
          for (final g in r.grants.entries) g.key: ?levelOf(g.value),
        },
        endsAt: r.endsAt,
      );
    }
  }

  @override
  void dispose() {
    _watch?.cancel();
    _keepTimer?.cancel();
    // Closed (Escape, the scrim) before the code was kept: withdrawn.
    final made = _made;
    final service = _service;
    if (made != null && !_kept && service != null) {
      unawaited(service.withdrawInvite(widget.orchard.id, made.inviteId).catchError((Object e) {
        AppLogger.warning('Orchards: a code closed unkept was not withdrawn (${errorKind(e)})');
      }));
    }
    _email.removeListener(_typed);
    _email.dispose();
    super.dispose();
  }

  // ── Email ──

  /// A list pasted or typed with separators becomes chips; what is left
  /// stays in the field.
  void _typed() {
    final text = _email.text;
    if (!text.contains(RegExp(r'[,;\s]'))) {
      if (mounted) setState(() {});
      return;
    }
    final parts = text.split(RegExp(r'[,;\s]+'));
    final last = parts.removeLast();
    final added = _addAll(parts);
    if (added) {
      _email.value = TextEditingValue(text: last, selection: TextSelection.collapsed(offset: last.length));
    }
    if (mounted) setState(() => _error = null);
  }

  /// Adds [given] to the list: an address once, a repeat noted, anything
  /// else set aside. Whether anything was given.
  bool _addAll(Iterable<String> given) {
    var any = false;
    for (final p in given) {
      final raw = p.trim();
      final e = raw.toLowerCase();
      if (e.isEmpty) continue;
      any = true;
      if (e.length > 320 || !_emailShape.hasMatch(e)) {
        if (!_bad.contains(raw)) _bad.add(raw);
      } else if (_emails.contains(e)) {
        _twice.add(e);
      } else {
        _emails.add(e);
      }
    }
    return any;
  }

  /// A CSV or any text file: every address in it joins the list.
  Future<void> _importFile() async {
    final l10n = AppLocalizations.of(context)!;
    String? text;
    try {
      text = await ref.read(inviteAddressFileProvider)();
    } catch (e) {
      AppLogger.warning('Orchards: a file of addresses was not read (${errorKind(e)})');
      if (mounted) setState(() => _error = l10n.inviteCsvNone);
      return;
    }
    if (text == null || !mounted) return;
    final found = addressesIn(text);
    setState(() {
      if (found.isEmpty) {
        _error = l10n.inviteCsvNone;
      } else {
        _addAll(found);
        _error = null;
      }
    });
  }

  List<String> get _allEmails {
    final rest = _email.text.trim().toLowerCase();
    return [..._emails, if (rest.isNotEmpty && !_emails.contains(rest)) rest];
  }

  Future<void> _send() async {
    final l10n = AppLocalizations.of(context)!;
    final offer = _offer;
    final emails = _allEmails;
    if (offer == null) return;
    final bad = emails.where((e) => e.length > 320 || !_emailShape.hasMatch(e)).toList();
    // One address and it is none: said. In a list, what is no address is
    // left out (the check list says so) and the rest go.
    if (emails.isEmpty || (bad.isNotEmpty && emails.length == 1 && _emails.isEmpty)) {
      setState(() => _error = l10n.orchardInviteEmailInvalid);
      return;
    }
    if (bad.isNotEmpty) {
      _bad.addAll(bad.where((b) => !_bad.contains(b)));
      emails.removeWhere(bad.contains);
      if (emails.isEmpty) {
        setState(() => _error = l10n.orchardInviteEmailInvalid);
        return;
      }
    }
    setState(() {
      _busy = true;
      _error = null;
      _seatsNeeded = null;
    });
    final sent = <String>[];
    var emailed = false;
    String? firstFailure;
    for (final email in emails) {
      try {
        emailed = await ref.read(orchardServiceProvider).invite(widget.orchard.id,
                email: email, role: offer.role, grants: offer.grants, endsAt: offer.endsAt) ||
            emailed;
        sent.add(email);
      } catch (e) {
        AppLogger.warning('Orchards: an invitation was not sent (${errorKind(e)})');
        final seats = inviteSeatsNeededOf(e);
        if (seats != null) {
          // What the server said this one needs, and one more for each
          // address after it.
          _seatsNeeded = seats + emails.length - sent.length - 1;
          break;
        }
        firstFailure ??= emails.length == 1
            ? inviteErrorMessage(e, l10n)
            : l10n.inviteNotSentTo(Redactable.account(email).displayIn(ref), inviteErrorMessage(e, l10n));
      }
    }
    if (!mounted) return;
    if (sent.length == emails.length) {
      Navigator.of(context).pop(InviteDialogResult(sent: sent, emailed: emailed));
      return;
    }
    // Those not sent stay, to try again.
    setState(() {
      _busy = false;
      _emails
        ..clear()
        ..addAll(emails.where((e) => !sent.contains(e)));
      _email.clear();
      _error = firstFailure;
    });
    if (sent.isNotEmpty) ref.read(orchardInvitesVersionProvider.notifier).state++;
  }

  // ── Code ──

  JoinOffer _shown(InviteOffer offer, List<OrchardRoleView> roles, AppLocalizations l10n) => JoinOffer(
        team: widget.orchard.name ?? '',
        role: orchardRoleLabel(offer.role, l10n, names: {for (final r in roles) r.id: r.name}),
        vaults: [
          for (final v in offeredVaults(offer, widget.orchard, roles))
            JoinOfferVault(v.crate.name ?? l10n.crateUnnamed, v.level.name),
        ],
      );

  Future<void> _makeCode() async {
    final offer = _offer;
    if (offer == null || _making) return;
    final l10n = AppLocalizations.of(context)!;
    final roles = ref.read(orchardRolesProvider(widget.orchard.id)).valueOrNull ?? const <OrchardRoleView>[];
    final old = _made;
    setState(() {
      _making = true;
      _codeError = null;
      _codeSeatsNeeded = null;
    });
    final service = ref.read(orchardServiceProvider);
    _service = service;
    try {
      // A code names its offer in its tags: a changed offer is a new code,
      // and the old one goes first (its seat with it).
      if (old != null) {
        await service.withdrawInvite(widget.orchard.id, old.inviteId);
      }
      final made = await service.makeInviteCode(
        widget.orchard.id,
        role: offer.role,
        grants: offer.grants,
        endsAt: offer.endsAt,
        expiresIn: _expiresIn,
        shown: _shown(offer, roles, l10n),
        replacesInvite: widget.replacing?.id,
        usesMax: widget.replacing == null ? _usesMax : 1,
      );
      if (!mounted) return;
      ref.invalidate(orchardBillingProvider(widget.orchard.id));
      setState(() {
        _made = made;
        _expiresAt = made.expiresAt;
        _remade = old != null;
        _usedBy = null;
        _kept = false;
      });
      _keepTimer?.cancel();
      _keepTimer = Timer(_keepAfter, _keep);
      _watchForUse();
    } catch (e) {
      AppLogger.warning('Orchards: an invite code was not made (${errorKind(e)})');
      if (!mounted) return;
      setState(() {
        if (old != null) _made = null;
        _codeSeatsNeeded = inviteSeatsNeededOf(e);
        _codeError = _codeSeatsNeeded == null ? inviteErrorMessage(e, l10n) : null;
      });
    } finally {
      if (mounted) setState(() => _making = false);
    }
  }

  /// Whoever uses the code shows up here too, while the dialog is open: on
  /// the server's word that someone waits (the live line), and every 15
  /// seconds.
  void _watchForUse() {
    _watch?.cancel();
    _watch = Timer.periodic(const Duration(seconds: 15), (_) => unawaited(_checkUsed()));
  }

  Future<void> _checkUsed() async {
    final made = _made;
    if (made == null || _usedBy != null) return;
    try {
      final list = await ref.read(orchardServiceProvider).invites(widget.orchard.id);
      final mine = list.where((i) => i.id == made.inviteId && i.accepted).firstOrNull;
      if (mine != null && mounted) {
        _watch?.cancel();
        setState(() => _usedBy = mine);
        ref.read(orchardInvitesVersionProvider.notifier).state++;
      }
    } catch (e) {
      AppLogger.info('Orchards: the invite code could not be checked for use (${errorKind(e)})');
    }
  }

  Future<void> _changeExpiry(int seconds) async {
    final made = _made;
    setState(() => _expiresIn = seconds);
    if (made == null) return;
    try {
      final at = await ref.read(orchardServiceProvider).changeInviteCodeExpiry(widget.orchard.id, made.inviteId, seconds);
      if (mounted) setState(() => _expiresAt = at);
    } catch (e) {
      AppLogger.warning('Orchards: an invite code kept its expiry (${errorKind(e)})');
      if (mounted) showTopSnackBar(context, inviteErrorMessage(e, AppLocalizations.of(context)!), isError: true, details: '$e');
    }
  }

  Future<void> _cancelCode() async {
    final made = _made;
    final l10n = AppLocalizations.of(context)!;
    if (made == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(orchardServiceProvider).withdrawInvite(widget.orchard.id, made.inviteId);
      // Withdrawn: nothing is left for closing to withdraw.
      _made = null;
      ref.invalidate(orchardBillingProvider(widget.orchard.id));
      if (!mounted) return;
      showTopSnackBar(context, l10n.inviteCodeCancelled);
      Navigator.of(context).pop(const InviteDialogResult(code: true));
    } catch (e) {
      AppLogger.warning('Orchards: an invite code was not cancelled (${errorKind(e)})');
      if (mounted) {
        setState(() => _busy = false);
        showTopSnackBar(context, inviteErrorMessage(e, l10n), isError: true, details: '$e');
      }
    }
  }

  /// The code made is kept from now on: listed under Invited.
  void _keep() {
    _keepTimer?.cancel();
    if (_kept || _made == null || !mounted) return;
    setState(() => _kept = true);
    ref.read(orchardInvitesVersionProvider.notifier).state++;
  }

  /// Done: a code not kept yet is withdrawn first.
  Future<void> _done() async {
    final made = _made;
    if (made != null && !_kept) {
      _keepTimer?.cancel();
      setState(() => _busy = true);
      try {
        await ref.read(orchardServiceProvider).withdrawInvite(widget.orchard.id, made.inviteId);
        ref.invalidate(orchardBillingProvider(widget.orchard.id));
      } catch (e) {
        AppLogger.warning('Orchards: a code closed unkept was not withdrawn (${errorKind(e)})');
      }
      _made = null;
      if (mounted) Navigator.of(context).pop(const InviteDialogResult());
      return;
    }
    Navigator.of(context).pop(InviteDialogResult(code: made != null));
  }

  Future<void> _copy(String text, String said) async {
    if (!await confirmRevealWhileRecording(context, ref) || !mounted) return;
    _keep();
    // A code or its link lets whoever holds it ask to join: it leaves the
    // clipboard by itself, as a secret does, and the person is told (the
    // found in a security review); after 3 minutes and not the 45 seconds of
    // other secrets, time enough to paste it into a chat to someone else.
    await SecretClipboard.copy(text, life: kInviteClipboardLife);
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    showTopSnackBar(context, clearsSoon(l10n, said, note: l10n.inviteClipboardAutoClearNote), isSuccess: true);
  }

  Future<void> _changeOffer(List<OrchardRoleView> roles) async {
    final current = _offer;
    if (current == null) return;
    final l10n = AppLocalizations.of(context)!;
    final picked = await showZestModal<InviteOffer>(
      context: context,
      size: ZestModalSize.standard,
      child: _OfferDialog(orchard: widget.orchard, offer: current, title: l10n.inviteWhatTheyGet),
    );
    if (picked == null || !mounted || picked.sameAs(current)) return;
    setState(() => _offer = picked);
    if (_made != null) await _makeCode();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final rolesRead = ref.watch(orchardRolesProvider(widget.orchard.id));
    final roles = rolesRead.valueOrNull ?? const <OrchardRoleView>[];
    final offerable = offerableRoles(widget.orchard, roles, l10n);
    // The first role offered (the least) until another is picked, once the
    // roles are read: before, only Admin would be on offer.
    if (_offer == null && !rolesRead.isLoading && offerable.isNotEmpty) _offer = InviteOffer(role: offerable.first.id);
    // Someone who waits shows up here while it is open (the live line).
    ref.listen(orchardSummariesProvider, (_, _) {
      if (_way == InviteWay.code) unawaited(_checkUsed());
    });
    // Nothing is made until Make code:
    // opening the dialog, or this tab, costs nothing.
    final code = _way == InviteWay.code;
    return ZestDialogShell(
      size: ZestModalSize.large,
      tone: ZestDialogTone.info,
      icon: LucideIcons.userPlus,
      title: l10n.orchardInviteTitle(orchardDisplayName(widget.orchard.name, l10n)),
      subtitle: l10n.inviteDialogSubtitle,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.replacing == null) ...[
            _WayChoice(
              way: _way,
              onChanged: _busy || _making ? null : (w) => setState(() => _way = w),
            ),
            const SizedBox(height: 14),
          ],
          if (code) ..._codeBody(l10n, roles) else ..._emailBody(l10n),
        ],
      ),
      primaryKey: ValueKey(code ? 'invite-done' : 'invite-send'),
      primaryAction: code
          ? (label: l10n.done, onPressed: _busy ? null : _done, icon: null)
          : (
              label: _allEmails.length > 1 ? l10n.inviteSendSeveral : l10n.orchardInviteSend,
              onPressed: _busy || _offer == null || _guestBlocked ? null : _send,
              icon: LucideIcons.send,
            ),
      secondaryAction: code ? null : (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
      tertiaryKey: const ValueKey('invite-code-cancel'),
      tertiaryAction: code && _made != null && _usedBy == null ? (label: l10n.inviteCodeCancel, onPressed: _busy ? null : _cancelCode) : null,
      tertiaryDanger: true,
    );
  }

  // ── Guests ──

  bool get _guestAny {
    final proven = ref.read(orchardProvenDomainsProvider(widget.orchard.id)).valueOrNull ?? const <String>[];
    if (proven.isEmpty) return false;
    return _allEmails.any((e) {
      final at = e.lastIndexOf('@');
      final domain = at < 0 ? '' : e.substring(at + 1);
      return domain.contains('.') && !proven.contains(domain);
    });
  }

  bool _isGuest(String e) {
    final proven = ref.read(orchardProvenDomainsProvider(widget.orchard.id)).valueOrNull ?? const <String>[];
    if (proven.isEmpty) return false;
    final at = e.lastIndexOf('@');
    final domain = at < 0 ? '' : e.substring(at + 1);
    return domain.contains('.') && !proven.contains(domain);
  }

  bool get _guestBlocked => _guestAny && (!widget.orchard.isOwner || _offer?.endsAt == null);

  List<Widget> _emailBody(AppLocalizations l10n) {
    ref.watch(orchardProvenDomainsProvider(widget.orchard.id));
    final help = TextStyle(fontSize: 12, height: 1.45, color: ZestTokens.textTertiary);
    final seats = ref.watch(orchardBillingProvider(widget.orchard.id)).valueOrNull?.seats;
    final count = _allEmails.length;
    // Short of seats: said before anything is sent (every seat taken, or
    // fewer free than addresses), with how many more and who buys them.
    final wanted = max(count, 1);
    final needed = _seatsNeeded ??
        (seats != null && seats.free < wanted ? max(1, seats.used + wanted - seats.total) : null);
    return [
      Row(
        children: [
          Expanded(
            child: Text(l10n.inviteEmailsLabel,
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
          ),
          TextButton.icon(
            key: const ValueKey('invite-import-csv'),
            onPressed: _busy ? null : _importFile,
            icon: const Icon(LucideIcons.fileSpreadsheet, size: 14),
            label: Text(l10n.inviteImportCsv),
          ),
        ],
      ),
      const SizedBox(height: 6),
      _EmailChips(
        controller: _email,
        emails: _emails,
        error: _error,
        enabled: !_busy,
        onRemove: (e) => setState(() {
          _emails.remove(e);
          _twice.remove(e);
        }),
        onSubmit: _busy ? null : _send,
      ),
      if (_allEmails.length > 1 || _twice.isNotEmpty || _bad.isNotEmpty) ...[
        const SizedBox(height: 8),
        _CheckList(
          rows: [
            for (final e in _allEmails)
              (
                e,
                _twice.contains(e)
                    ? l10n.inviteCheckTwice
                    : _isGuest(e)
                        ? l10n.inviteCheckGuest
                        : l10n.inviteCheckWill,
                false,
              ),
            for (final b in _bad) (b, l10n.inviteCheckBad, true),
          ],
        ),
      ],
      if (_error != null) ...[
        const SizedBox(height: 4),
        Text(_error!,
            key: const ValueKey('invite-email-error'),
            style: TextStyle(fontSize: 12, height: 1.4, color: ZestTokens.statusCritical)),
      ],
      const SizedBox(height: 6),
      Text(l10n.orchardInviteExplainer, style: help),
      const SizedBox(height: 16),
      ZestSectionLabel(l10n.inviteWhatTheyGet),
      const SizedBox(height: 8),
      if (_offer != null)
        InviteOfferEditor(
          orchard: widget.orchard,
          offer: _offer!,
          enabled: !_busy,
          onChanged: (o) => setState(() => _offer = o),
        ),
      if (_guestAny) ...[
        const SizedBox(height: 8),
        Text(
          widget.orchard.isOwner ? l10n.orchardGuestNote : l10n.orchardGuestOwnersOnly,
          key: const ValueKey('invite-guest'),
          style: TextStyle(fontSize: 12, height: 1.4, color: ZestTokens.statusWarning),
        ),
      ],
      const SizedBox(height: 14),
      if (needed != null)
        InviteSeatsNote(orchard: widget.orchard, needed: needed)
      else if (seats != null && count > 0)
        _FootNote(
          key: const ValueKey('invite-seat-effect'),
          icon: LucideIcons.armchair,
          text: seats.free == 1 && count == 1 ? l10n.inviteSeatLast : l10n.inviteSeatsTake(count, seats.free),
        ),
    ];
  }

  List<Widget> _codeBody(AppLocalizations l10n, List<OrchardRoleView> roles) {
    final offer = _offer;
    final made = _made;
    final seats = ref.watch(orchardBillingProvider(widget.orchard.id)).valueOrNull?.seats;
    return [
      if (offer != null)
        _OfferSummary(
          orchard: widget.orchard,
          offer: offer,
          roles: roles,
          onChange: _making || _busy || _usedBy != null ? null : () => _changeOffer(roles),
        ),
      const SizedBox(height: 12),
      if (_codeSeatsNeeded != null)
        InviteSeatsNote(orchard: widget.orchard, needed: _codeSeatsNeeded!)
      else if (_codeError != null) ...[
        Text(_codeError!,
            key: const ValueKey('invite-code-error'),
            style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.statusCritical)),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('invite-code-retry'),
            onPressed: () => setState(() => _codeError = null),
            icon: const Icon(LucideIcons.refreshCw, size: 14),
            label: Text(l10n.retry),
          ),
        ),
      ] else if (made == null && !_making && offer != null) ...[
        Row(
          children: [
            Expanded(
              child: Text(l10n.inviteCodeExpiryLabel,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
            ),
            ZestSelect<int>(
              key: const ValueKey('invite-code-expiry'),
              width: 170,
              value: _expiresIn,
              items: [for (final s in kInviteCodeExpiries) ZestSelectItem(s, _expiryWords(s, l10n))],
              onChanged: (v) => setState(() => _expiresIn = v),
            ),
          ],
        ),
        if (widget.replacing == null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(l10n.inviteCodeUsesLabel,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
              ),
              ZestSelect<int>(
                key: const ValueKey('invite-code-uses'),
                width: 170,
                value: _usesMax,
                items: [for (final n in kInviteCodeUses) ZestSelectItem(n, l10n.inviteCodePeople(n))],
                onChanged: (v) => setState(() => _usesMax = v),
              ),
            ],
          ),
          if (_usesMax > 1) ...[
            const SizedBox(height: 6),
            Text(l10n.inviteTeamCodeNote,
                key: const ValueKey('invite-code-team-note'),
                style: TextStyle(fontSize: 12, height: 1.45, color: ZestTokens.textSecondary)),
          ],
        ],
        const SizedBox(height: 14),
        Container(
          key: const ValueKey('invite-code-not-yet'),
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          decoration: BoxDecoration(
            color: ZestTokens.surfaceRaisedAlt,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: ZestTokens.borderSubtle),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(l10n.inviteCodeNotYet,
                    style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textSecondary)),
              ),
              const SizedBox(width: 12),
              teamButton(
                key: const ValueKey('invite-code-make'),
                kind: TeamButtonKind.primary,
                icon: LucideIcons.qrCode,
                label: l10n.inviteCodeMake,
                onPressed: _busy ? null : _makeCode,
              ),
            ],
          ),
        ),
      ] else if (made == null || _cancelling)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 10),
                Text(l10n.inviteCodeMaking, style: TextStyle(fontSize: 13, color: ZestTokens.textSecondary)),
              ],
            ),
          ),
        )
      else ...[
        _CodeCard(
          code: made.code,
          expiresAt: _expiresAt ?? made.expiresAt,
          expiresIn: _expiresIn,
          seats: seats,
          onExpiry: _usedBy != null ? null : _changeExpiry,
          onCopy: () => _copy(writtenJoinCode(made.code), l10n.inviteCodeCopied),
          onCopyLink: () => _copy(joinCodeLink(made.code), l10n.inviteCodeLinkCopied),
          onReveal: () => confirmRevealWhileRecording(context, ref),
        ),
        if (_remade) ...[
          const SizedBox(height: 8),
          Text(l10n.inviteCodeRemade,
              key: const ValueKey('invite-code-remade'),
              style: TextStyle(fontSize: 12, height: 1.4, color: ZestTokens.textSecondary)),
        ],
        if (!_kept) ...[
          const SizedBox(height: 8),
          Text(l10n.inviteCodeKeepNote,
              key: const ValueKey('invite-code-keep-note'),
              style: TextStyle(fontSize: 12, height: 1.4, color: ZestTokens.textTertiary)),
        ],
        const SizedBox(height: 12),
        if (_usedBy case final used?)
          _UsedBox(invite: used)
        else
          _WaitingBox(title: l10n.inviteCodeWaitingTitle, body: l10n.inviteCodeWaitingBody),
        const SizedBox(height: 12),
        // A team code goes to several people, so each use is compared before
        // anyone is let in; a code for one person checks the keys.
        if (widget.replacing == null && _usesMax > 1)
          _FootNote(
              key: const ValueKey('invite-code-team-footnote'),
              icon: LucideIcons.fingerprint,
              text: l10n.inviteTeamCodeFootnote,
              tone: ZestTokens.statusHealthy)
        else
          _FootNote(icon: LucideIcons.shieldCheck, text: l10n.inviteCodeFootnote, tone: ZestTokens.statusHealthy),
      ],
    ];
  }
}

// ── Pieces ──────────────────────────────────────────────────────────────

/// A small upper-case section label, as the team's pages have them.
class ZestSectionLabel extends StatelessWidget {
  const ZestSectionLabel(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Container(width: 2, height: 12, color: ZestTokens.brand),
          const SizedBox(width: 8),
          Text(
            label.toUpperCase(),
            style: TextStyle(
              // A label: the app's own type on a phone and a tablet
              // (monospace is for values to copy; 3.0 quick wins).
              fontFamily: isTouchLayout ? null : 'JetBrainsMono',
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.1,
              color: ZestTokens.textTertiary,
            ),
          ),
        ],
      );
}

/// The two ways, side by side.
class _WayChoice extends StatelessWidget {
  const _WayChoice({required this.way, required this.onChanged});

  final InviteWay way;
  final ValueChanged<InviteWay>? onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    Widget card(InviteWay w, IconData icon, String title, String help) {
      final on = way == w;
      return Expanded(
        child: Semantics(
          selected: on,
          button: true,
          child: InkWell(
            key: ValueKey('invite-way-${w.name}'),
            borderRadius: BorderRadius.circular(8),
            onTap: onChanged == null ? null : () => onChanged!(w),
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: BoxDecoration(
                color: on ? ZestTokens.brandSubtle : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: on ? ZestTokens.brandBorder : Colors.transparent),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(icon, size: 16, color: on ? ZestTokens.brand : ZestTokens.textSecondary),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
                        const SizedBox(height: 2),
                        Text(help, style: TextStyle(fontSize: 11.5, height: 1.35, color: ZestTokens.textSecondary)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceSunken,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ZestTokens.borderSubtle),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          card(InviteWay.email, LucideIcons.mail, l10n.inviteWayEmail, l10n.inviteWayEmailHelp),
          const SizedBox(width: 4),
          card(InviteWay.code, LucideIcons.qrCode, l10n.inviteWayCode, l10n.inviteWayCodeHelp),
        ],
      ),
    );
  }
}

/// Each address given and what happens to it: invited, given twice (sent
/// once), a guest, or no address (left out).
class _CheckList extends ConsumerWidget {
  const _CheckList({required this.rows});

  /// The address, what is said of it, and whether it is left out.
  final List<(String, String, bool)> rows;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    ref.watch(recordingModeProvider);
    final head = TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.4, color: ZestTokens.textTertiary);
    return Container(
      key: const ValueKey('invite-check'),
      constraints: const BoxConstraints(maxHeight: 220),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ZestTokens.borderSubtle),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
            child: Row(children: [
              Expanded(child: Text(l10n.inviteCheckAddress.toUpperCase(), style: head)),
              Expanded(child: Text(l10n.inviteCheckResult.toUpperCase(), style: head)),
            ]),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: [
                for (final (address, said, left) in rows)
                  Container(
                    key: ValueKey('invite-check-$address'),
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                    decoration: BoxDecoration(border: Border(top: BorderSide(color: ZestTokens.borderSubtle))),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: RedactedText(Redactable.account(address),
                              style: TextStyle(
                                  fontSize: 12.5,
                                  color: left ? ZestTokens.textTertiary : ZestTokens.textPrimary,
                                  decoration: left ? TextDecoration.lineThrough : null)),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(said,
                              style: TextStyle(
                                  fontSize: 12,
                                  height: 1.35,
                                  color: left ? ZestTokens.statusWarning : ZestTokens.textSecondary)),
                        ),
                      ],
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

/// Addresses as chips, and a field for the next (a pasted list splits).
class _EmailChips extends ConsumerWidget {
  const _EmailChips({
    required this.controller,
    required this.emails,
    required this.error,
    required this.enabled,
    required this.onRemove,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final List<String> emails;
  final String? error;
  final bool enabled;
  final ValueChanged<String> onRemove;
  final VoidCallback? onSubmit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    ref.watch(recordingModeProvider);
    return Container(
      key: const ValueKey('invite-email'),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceSunken,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: error != null ? ZestTokens.statusCritical : ZestTokens.brandBorder),
      ),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final e in emails)
            InputChip(
              key: ValueKey('invite-chip-$e'),
              label: RedactedText(Redactable.account(e), style: const TextStyle(fontSize: 12.5)),
              onDeleted: enabled ? () => onRemove(e) : null,
              deleteButtonTooltipMessage: l10n.inviteEmailRemove(Redactable.account(e).displayIn(ref)),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 180, maxWidth: 420),
            child: IntrinsicWidth(
              // Lines are taken (a column pasted from a sheet keeps its line
              // breaks, which split it), and Enter still sends.
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.enter): () => onSubmit?.call(),
                  const SingleActivator(LogicalKeyboardKey.numpadEnter): () => onSubmit?.call(),
                },
                child: TextField(
                  controller: controller,
                  enabled: enabled,
                  autofocus: true,
                  keyboardType: TextInputType.emailAddress,
                  minLines: 1,
                  maxLines: null,
                  maxLength: 4000,
                  style: TextStyle(fontSize: 13, color: ZestTokens.textPrimary),
                  decoration: InputDecoration(
                    isDense: true,
                    counterText: '',
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    errorBorder: InputBorder.none,
                    focusedErrorBorder: InputBorder.none,
                    hintText: emails.isEmpty ? 'name@example.com' : l10n.inviteEmailsHint,
                    hintStyle: TextStyle(fontSize: 13, color: ZestTokens.textPlaceholder),
                  ),
                  onSubmitted: onSubmit == null ? null : (_) => onSubmit!(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Role chips, vaults with a level each, and when access ends.
class InviteOfferEditor extends ConsumerWidget {
  const InviteOfferEditor({
    super.key,
    required this.orchard,
    required this.offer,
    required this.onChanged,
    this.enabled = true,
  });

  final OrchardSummary orchard;
  final InviteOffer offer;
  final ValueChanged<InviteOffer> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final roles = ref.watch(orchardRolesProvider(orchard.id)).valueOrNull ?? const <OrchardRoleView>[];
    final offerable = offerableRoles(orchard, roles, l10n);
    final label = TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary);
    final help = TextStyle(fontSize: 11.5, height: 1.4, color: ZestTokens.textTertiary);
    final roleName = orchardRoleLabel(offer.role, l10n, names: {for (final r in roles) r.id: r.name});
    final vaults = [
      for (final c in orchard.crates)
        if (!c.ownersOnly &&
            (roleLevelIn(offer.role, c.id, roles, admin: orchard.adminRole) != null || handableLevels(c).isNotEmpty))
          c,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(l10n.orchardInviteRoleLabel, style: label),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final r in offerable)
              ChoiceChip(
                key: ValueKey('invite-role-${r.id}'),
                label: Text(r.label),
                selected: offer.role == r.id,
                onSelected: !enabled ? null : (_) => onChanged(offer.copyWith(role: r.id, extra: const {})),
              ),
          ],
        ),
        if (offer.role == FixedRoles.admin) ...[
          const SizedBox(height: 6),
          // As every team starts, or as an owner changed the Admin role.
          Text(orchard.adminRole == null ? l10n.orchardInviteRoleAdminHelp : l10n.orchardInviteRoleAdminChangedHelp,
              key: const ValueKey('invite-admin-help'), style: help),
        ] else if (vaults.isNotEmpty) ...[
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(child: Text(l10n.inviteVaultsLabel, style: label)),
              Text(l10n.inviteVaultsOwnersOnly, style: help),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: ZestTokens.borderSubtle),
            ),
            child: Column(
              children: [
                for (var i = 0; i < vaults.length; i++) ...[
                  if (i > 0) Divider(height: 1, thickness: 1, color: ZestTokens.borderSubtle),
                  _VaultRow(
                    key: ValueKey('invite-crate-${vaults[i].id}'),
                    crate: vaults[i],
                    own: roleLevelIn(offer.role, vaults[i].id, roles, admin: orchard.adminRole),
                    level: _effective(offer, vaults[i].id, roles, orchard.adminRole),
                    roleName: roleName,
                    handable: handableLevels(vaults[i]),
                    onChanged: !enabled
                        ? null
                        : (level) {
                            final own = roleLevelIn(offer.role, vaults[i].id, roles, admin: orchard.adminRole);
                            final extra = {...offer.extra}..remove(vaults[i].id);
                            if (level != null && (own == null || level.index > own.index)) {
                              extra[vaults[i].id] = level;
                            }
                            onChanged(offer.copyWith(extra: extra));
                          },
                  ),
                ],
              ],
            ),
          ),
        ],
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(child: Text(l10n.inviteAccessEnds, style: label)),
            ZestSelect<String>(
              key: const ValueKey('invite-ends'),
              width: 190,
              value: offer.endsAt == null ? 'never' : 'date',
              items: [
                ZestSelectItem('never', l10n.inviteAccessNever),
                if (offer.endsAt != null) ZestSelectItem('date', accessThrough(offer.endsAt!, context)),
              ],
              onChanged: !enabled
                  ? null
                  : (v) {
                      if (v == 'never') onChanged(offer.copyWith(endsAt: () => null));
                    },
              actions: [
                ZestSelectAction(
                  l10n.inviteAccessPick,
                  onPressed: () async {
                    final picked = await pickAccessEnd(context, title: l10n.orchardEndDateTitleInvite, current: offer.endsAt);
                    if (picked != null) onChanged(offer.copyWith(endsAt: () => picked.endsAt));
                  },
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

/// A vault and its level: the role's own, or one above it ("Extra").
class _VaultRow extends StatelessWidget {
  const _VaultRow({
    super.key,
    required this.crate,
    required this.own,
    required this.level,
    required this.roleName,
    required this.handable,
    required this.onChanged,
  });

  final CrateSummary crate;
  final CrateLevel? own;
  final CrateLevel? level;
  final String roleName;
  final List<CrateLevel> handable;
  final ValueChanged<CrateLevel?>? onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final extra = level != null && (own == null || level!.index > own!.index);
    final options = <CrateLevel?>[
      own,
      for (final l in handable)
        if (own == null || l.index > own!.index) l,
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Row(
        children: [
          Icon(LucideIcons.box, size: 16, color: ZestTokens.textSecondary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: RedactedText(
                        Redactable.group(crateDisplayName(crate, l10n)),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary),
                      ),
                    ),
                    if (extra) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: ZestTokens.brandSubtle,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(l10n.inviteVaultExtra, style: TextStyle(fontSize: 10.5, color: ZestTokens.brandInk)),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  own == null
                      ? l10n.inviteVaultRoleGivesNone(roleName)
                      : l10n.inviteVaultFromRole(crateLevelName(own!, l10n), roleName),
                  style: TextStyle(fontSize: 11.5, color: ZestTokens.textTertiary),
                ),
              ],
            ),
          ),
          // The app's select (it was a Material dropdown
          // before).
          ZestSelect<CrateLevel?>(
            value: level,
            width: 140,
            items: [
              for (final o in options) ZestSelectItem(o, o == null ? l10n.crateLevelNone : crateLevelName(o, l10n)),
            ],
            onChanged: onChanged == null || options.length < 2 ? null : onChanged,
          ),
        ],
      ),
    );
  }
}

/// "Joins as Member · Shared: Use · no end date", and Change.
class _OfferSummary extends ConsumerWidget {
  const _OfferSummary({required this.orchard, required this.offer, required this.roles, required this.onChange});

  final OrchardSummary orchard;
  final InviteOffer offer;
  final List<OrchardRoleView> roles;
  final VoidCallback? onChange;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    ref.watch(recordingModeProvider);
    final role = orchardRoleLabel(offer.role, l10n, names: {for (final r in roles) r.id: r.name});
    // Admin as every team starts opens every vault (said by its role); once
    // an owner changed it, the vaults it opens are named like any role's.
    final vaults = offer.role == FixedRoles.admin && orchard.adminRole == null
        ? const <({CrateSummary crate, CrateLevel level})>[]
        : offeredVaults(offer, orchard, roles);
    final named = vaults.take(2).map((v) => l10n.inviteSummaryVault(
        Redactable.group(crateDisplayName(v.crate, l10n)).display, crateLevelName(v.level, l10n)));
    final rest = [
      ...named,
      if (vaults.length > 2) l10n.inviteSummaryMore(vaults.length - 2),
      offer.endsAt == null ? l10n.inviteSummaryNoEnd : l10n.inviteSummaryUntil(accessThrough(offer.endsAt!, context)),
    ];
    final joins = l10n.inviteJoinsAs(role);
    final at = joins.indexOf(role);
    final base = TextStyle(fontSize: 13, color: ZestTokens.textSecondary);
    final bold = TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary);
    return Container(
      key: const ValueKey('invite-summary'),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ZestTokens.borderSubtle),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.lock, size: 14, color: ZestTokens.textSecondary),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(style: base, children: [
                if (at < 0)
                  TextSpan(text: joins)
                else ...[
                  TextSpan(text: joins.substring(0, at)),
                  TextSpan(text: role, style: bold),
                  TextSpan(text: joins.substring(at + role.length)),
                ],
                for (final r in rest) TextSpan(text: ' · $r'),
              ]),
            ),
          ),
          TextButton(
            key: const ValueKey('invite-summary-change'),
            onPressed: onChange,
            child: Text(l10n.inviteChange),
          ),
        ],
      ),
    );
  }
}

/// The offer, changed in a dialog of its own (the code's Change).
class _OfferDialog extends ConsumerStatefulWidget {
  const _OfferDialog({required this.orchard, required this.offer, required this.title});

  final OrchardSummary orchard;
  final InviteOffer offer;
  final String title;

  @override
  ConsumerState<_OfferDialog> createState() => _OfferDialogState();
}

class _OfferDialogState extends ConsumerState<_OfferDialog> {
  late InviteOffer _offer = widget.offer;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: ZestDialogTone.info,
      icon: LucideIcons.slidersHorizontal,
      title: widget.title,
      body: InviteOfferEditor(orchard: widget.orchard, offer: _offer, onChanged: (o) => setState(() => _offer = o)),
      primaryKey: const ValueKey('invite-offer-save'),
      primaryAction: (label: l10n.save, onPressed: () => Navigator.of(context).pop(_offer), icon: null),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
    );
  }
}

/// The code: its QR code (the link), the code itself, copy, how long it
/// works and the seat it holds. Hidden while recording.
class _CodeCard extends ConsumerWidget {
  const _CodeCard({
    required this.code,
    required this.expiresAt,
    required this.expiresIn,
    required this.seats,
    required this.onExpiry,
    required this.onCopy,
    required this.onCopyLink,
    required this.onReveal,
  });

  final String code;
  final DateTime expiresAt;
  final int expiresIn;
  final OrchardSeats? seats;
  final ValueChanged<int>? onExpiry;
  final VoidCallback onCopy;
  final VoidCallback onCopyLink;
  final VoidCallback onReveal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final recording = ref.watch(recordingModeProvider);
    final local = expiresAt.toLocal();
    final now = DateTime.now();
    final sameDay = local.year == now.year && local.month == now.month && local.day == now.day;
    final ends = plainTimeSpaces(sameDay ? l10n.inviteCodeEndsAt(local) : l10n.inviteCodeEndsOnAt(local, local));
    final link = joinCodeLink(code);
    final qr = recording
        ? Container(
            key: const ValueKey('invite-code-qr-hidden'),
            width: 150,
            constraints: const BoxConstraints(minHeight: 150),
            alignment: Alignment.center,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: ZestTokens.surfaceSunken,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: ZestTokens.border),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(LucideIcons.eyeOff, size: 20, color: ZestTokens.textSecondary),
                const SizedBox(height: 6),
                Text(l10n.twoStepHiddenWhileRecording,
                    textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: ZestTokens.textSecondary)),
                TextButton(onPressed: onReveal, child: Text(l10n.twoStepShow)),
              ],
            ),
          )
        : Container(
            key: const ValueKey('invite-code-qr'),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10)),
            child: SizedBox.square(
              dimension: 134,
              child: QrImageView(
                data: link,
                version: QrVersions.auto,
                size: 134,
                gapless: true,
                backgroundColor: Colors.white,
                errorCorrectionLevel: QrErrorCorrectLevel.M,
                eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Color(0xFF0A0A0A)),
                dataModuleStyle:
                    const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: Color(0xFF0A0A0A)),
              ),
            ),
          );
    final shownCode = recording ? 'ZEST-••••-••••-••••' : writtenJoinCode(code);
    final shownLink = recording ? '$kJoinLinkBase#••••' : link.replaceFirst('https://', '');
    final mono = TextStyle(fontFamily: 'JetBrainsMono', fontSize: 16, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary);
    final small = TextStyle(fontSize: 12.5, color: ZestTokens.textSecondary);
    final seatText = seats == null
        ? l10n.inviteCodeHoldsSeatPlain
        : l10n.inviteCodeHoldsSeat(seats!.used, seats!.total);
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.inviteCodeLabel, style: small),
        const SizedBox(height: 4),
        SelectableText(shownCode, key: const ValueKey('invite-code-text'), style: mono),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('invite-code-copy'),
              onPressed: onCopy,
              icon: const Icon(LucideIcons.copy, size: 14),
              label: Text(l10n.inviteCodeCopy),
            ),
            OutlinedButton.icon(
              key: const ValueKey('invite-code-copy-link'),
              onPressed: onCopyLink,
              icon: const Icon(LucideIcons.link, size: 14),
              label: Text(l10n.inviteCodeCopyLink),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(shownLink,
            style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11, color: ZestTokens.textTertiary),
            overflow: TextOverflow.ellipsis),
        const SizedBox(height: 10),
        _Line(icon: LucideIcons.info, text: l10n.inviteCodeWorksOnce),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(child: _Line(icon: LucideIcons.clock, text: ends, key: const ValueKey('invite-code-ends'))),
            ZestSelect<int>(
              key: const ValueKey('invite-code-expiry'),
              width: 170,
              value: expiresIn,
              items: [for (final s in kInviteCodeExpiries) ZestSelectItem(s, _expiryWords(s, l10n))],
              onChanged: onExpiry,
            ),
          ],
        ),
        const SizedBox(height: 4),
        _Line(icon: LucideIcons.armchair, text: seatText, key: const ValueKey('invite-code-seat')),
      ],
    );
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ZestTokens.borderSubtle),
      ),
      child: LayoutBuilder(builder: (context, box) {
        final scan = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            qr,
            const SizedBox(height: 6),
            Text(l10n.inviteCodeScanWith, style: TextStyle(fontSize: 11.5, color: ZestTokens.textTertiary)),
          ],
        );
        if (box.maxWidth < 440) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [Center(child: scan), const SizedBox(height: 12), details]);
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [scan, const SizedBox(width: 16), Expanded(child: details)],
        );
      }),
    );
  }
}

String _expiryWords(int seconds, AppLocalizations l10n) => switch (seconds) {
      3600 => l10n.inviteCodeExpiryHour,
      86400 => l10n.inviteCodeExpiryDay,
      604800 => l10n.inviteCodeExpiryWeek,
      _ => l10n.inviteCodeExpiryMonth,
    };

class _Line extends StatelessWidget {
  const _Line({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, size: 13, color: ZestTokens.textTertiary)),
          const SizedBox(width: 6),
          Expanded(child: Text(text, style: TextStyle(fontSize: 12.5, height: 1.4, color: ZestTokens.textSecondary))),
        ],
      );
}

class _WaitingBox extends StatelessWidget {
  const _WaitingBox({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Container(
        key: const ValueKey('invite-code-waiting'),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: ZestTokens.brandSubtle,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: ZestTokens.brandBorder),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.8)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
                  const SizedBox(height: 2),
                  Text(body, style: TextStyle(fontSize: 12.5, height: 1.4, color: ZestTokens.textSecondary)),
                ],
              ),
            ),
          ],
        ),
      );
}

class _UsedBox extends ConsumerWidget {
  const _UsedBox({required this.invite});

  final OrchardInvite invite;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final green = ZestTokens.statusHealthy;
    return Container(
      key: const ValueKey('invite-code-used'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: green.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: green.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.userCheck, size: 16, color: green),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.inviteCodeUsedBy(Redactable.account(invite.email).displayIn(ref)),
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
                const SizedBox(height: 2),
                Text(l10n.inviteCodeUsedBody, style: TextStyle(fontSize: 12.5, height: 1.4, color: ZestTokens.textSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FootNote extends StatelessWidget {
  const _FootNote({super.key, required this.icon, required this.text, this.tone});

  final IconData icon;
  final String text;
  final Color? tone;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 14, color: tone ?? ZestTokens.textTertiary),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(fontSize: 12, height: 1.45, color: ZestTokens.textSecondary))),
        ],
      );
}

/// Where an invitation has no seat: how many more it needs, and who
/// buys them where. An owner on a computer buys exactly those from the seats
/// sheet; on a phone or tablet nothing is bought or pointed to, and
/// anyone else is told to ask an owner.
class InviteSeatsNote extends ConsumerWidget {
  const InviteSeatsNote({super.key, required this.orchard, required this.needed});

  final OrchardSummary orchard;
  final int needed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final buys = orchard.isOwner && ref.watch(billingOnThisDeviceProvider);
    final warn = ZestTokens.statusWarning;
    return Container(
      key: const ValueKey('invite-seats'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: warn.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: warn.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(padding: const EdgeInsets.only(top: 1), child: Icon(LucideIcons.users, size: 15, color: warn)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.inviteSeatsNeeded(needed),
                  key: const ValueKey('invite-seats-needed'),
                  style: TextStyle(fontSize: 12.5, height: 1.4, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (buys)
            OutlinedButton.icon(
              key: const ValueKey('invite-seats-buy'),
              icon: const Icon(LucideIcons.armchair, size: 14),
              label: Text(l10n.inviteSeatsBuy(needed)),
              onPressed: () => openSeatsSheet(context, ref, orchard.id, need: needed),
            )
          else
            Text(
              orchard.isOwner ? l10n.teamSeatsOnComputer : l10n.teamSeatsAskOwner,
              key: const ValueKey('invite-seats-where'),
              style: TextStyle(fontSize: 12, height: 1.4, color: ZestTokens.textSecondary),
            ),
        ],
      ),
    );
  }
}
