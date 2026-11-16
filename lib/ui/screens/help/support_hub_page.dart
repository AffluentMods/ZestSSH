import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/feedback/feedback_report.dart';
import 'package:zestssh/features/feedback/feedback_service.dart';
import 'package:zestssh/features/shortcuts/tablet_shortcuts.dart' show textFieldHasKeyboard;
import 'package:zestssh/features/tickets/public_reports.dart';
import 'package:zestssh/features/tickets/ticket_models.dart';
import 'package:zestssh/features/tickets/ticket_service.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/help_dock_provider.dart';
import 'package:zestssh/providers/help_status_provider.dart';
import 'package:zestssh/services/cloud/cloud_failure.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/help/help_form_parts.dart';
import 'package:zestssh/ui/screens/help/report_issue_screen.dart' show ScreenshotCapture;
import 'package:zestssh/ui/screens/help/support_hub_compose.dart';
import 'package:zestssh/ui/screens/help/support_hub_parts.dart';
import 'package:zestssh/ui/screens/help/support_hub_reports.dart';
import 'package:zestssh/ui/screens/help/ticket_detail_screen.dart';
import 'package:zestssh/ui/screens/help/ticket_widgets.dart';
import 'package:zestssh/ui/screens/help/tickets_screen.dart' show checkTickets;
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';

/// Under this width the hub is the list, then a conversation, as on a phone.
const double kHubStackBelow = 800;

/// Under this width the top bar takes two rows: the tabs and the search have
/// no room beside each other in a long language.
const double kHubBarFoldBelow = 1040;

/// How many closed tickets the list shows before "Show N more closed".
const int kHubClosedShown = 2;

/// One line of My tickets: a ticket, or a report still waiting to be sent,
/// which becomes a ticket under the same nonce once it is.
class _Entry {
  const _Entry.ticket(SupportTicketRow this.ticket) : report = null;
  const _Entry.report(FeedbackReport this.report) : ticket = null;

  final SupportTicketRow? ticket;
  final FeedbackReport? report;

  String get nonce => ticket?.nonce ?? report!.nonce;

  TicketType get type =>
      ticket?.ticketType ?? (report!.type == FeedbackType.bug ? TicketType.bug : TicketType.suggestion);

  /// Every word the search looks in.
  String get searchable {
    final t = ticket;
    if (t != null) {
      return [t.title, ticketNumberLabel(t.number), t.cachedConversation?.body ?? '', ...t.tagNames].join(' ').toLowerCase();
    }
    return '${report!.threadTitle} ${report!.body}'.toLowerCase();
  }

  _Group get group {
    final t = ticket;
    if (t == null) return _Group.waiting;
    if (t.isClosed || t.isGone) return _Group.closed;
    if (hubWaitsForYou(t)) return _Group.needsReply;
    if (t.ticketType == TicketType.suggestion && t.isSent) return _Group.ideas;
    return _Group.waiting;
  }
}

/// The groups of My tickets, in the order the design has them.
enum _Group { needsReply, waiting, ideas, closed }

/// The Support Hub : over the shell on
/// a computer, a page of its own on a phone. Three tabs: My tickets (what this
/// device sent, grouped by where it stands, with a conversation or a new
/// report beside them), Known issues and Ideas (everyone's, with +1). Esc
/// goes back to the sessions, which go on running behind it.
class SupportHubPage extends ConsumerStatefulWidget {
  const SupportHubPage({
    super.key,
    required this.captureScreenshot,
    required this.onClose,
  });

  /// A picture of the app without this page over it; null where the app
  /// cannot take one (a phone), and the screenshot is not offered.
  final ScreenshotCapture? captureScreenshot;
  final VoidCallback onClose;

  @override
  ConsumerState<SupportHubPage> createState() => _SupportHubPageState();
}

class _SupportHubPageState extends ConsumerState<SupportHubPage> {
  final _scope = FocusScopeNode(debugLabel: 'Support Hub');
  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'Support Hub search');

  bool _checking = false;
  bool _allClosed = false;

  /// The last try did not reach the server: what shows is what was read last.
  bool _stale = false;
  Object? _stopped;

  ModalRoute<Object?>? _route;

  @override
  void initState() {
    super.initState();
    _search.addListener(() {
      if (mounted) setState(() {});
    });
    FocusManager.instance.addListener(_keepKeyboard);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // The keyboard leaves the terminal behind, and comes back to it when this
      // page goes.
      if (mounted) _takeKeyboard();
      unawaited(_check());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  /// To this page, unless something is open over it: a dialog keeps its
  /// keyboard (F1 from under one took it away, and Esc closed this page while
  /// the dialog stayed).
  void _takeKeyboard() {
    if (_route?.isCurrent ?? true) _scope.requestFocus();
  }

  /// Back to this page where nothing holds the keyboard: the field that had it
  /// went (the form closed), or the dialog that had it did. Without it Esc does
  /// nothing here. A field elsewhere keeps it, and so does a window in the
  /// background, which gets back what it had by itself.
  void _keepKeyboard() {
    if (!mounted || _scope.hasFocus) return;
    final now = FocusManager.instance.primaryFocus;
    if (now != null && !_scope.ancestors.contains(now)) return;
    final life = WidgetsBinding.instance.lifecycleState;
    if (life != null && life != AppLifecycleState.resumed) return;
    _takeKeyboard();
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_keepKeyboard);
    _search.dispose();
    _searchFocus.dispose();
    _scope.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    if (_checking || !mounted) return;
    setState(() => _checking = true);
    final (reached, stopped) = await checkTickets(ref);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _stale = !reached;
      _stopped = stopped;
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      // In the search with words in it: those go first.
      if (_searchFocus.hasFocus && _search.text.isNotEmpty) {
        _search.clear();
        return KeyEventResult.handled;
      }
      widget.onClose();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.slash && !textFieldHasKeyboard() && ref.read(supportHubComposeProvider) == null) {
      _searchFocus.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _select(String? nonce) {
    ref.read(supportHubComposeProvider.notifier).state = null;
    ref.read(supportHubTicketProvider.notifier).state = nonce;
  }

  /// A new ticket or report, in My tickets beside the list.
  void _compose(TicketType kind) {
    ref.read(supportHubTabProvider.notifier).state = HubTab.myTickets;
    ref.read(supportHubComposeProvider.notifier).state = kind;
  }

  void _tab(HubTab tab) => ref.read(supportHubTabProvider.notifier).state = tab;

  @override
  Widget build(BuildContext context) {
    final tab = ref.watch(supportHubTabProvider);
    return FocusTraversalGroup(
      child: FocusScope(
        node: _scope,
        onKeyEvent: _onKey,
        child: Material(
          key: const ValueKey('support-hub'),
          color: AppColors.v3Background,
          child: LayoutBuilder(
            builder: (context, box) {
              final stacked = box.maxWidth < kHubStackBelow;
              final query = _search.text.trim();
              final Widget body = switch (tab) {
                HubTab.myTickets => _myTickets(context, stacked: stacked),
                HubTab.knownIssues => HubBoard(
                    key: const ValueKey('hub-known-issues'),
                    type: TicketType.bug,
                    query: query,
                    onCompose: () => _compose(TicketType.bug),
                  ),
                HubTab.ideas => HubBoard(
                    key: const ValueKey('hub-ideas'),
                    type: TicketType.suggestion,
                    query: query,
                    onCompose: () => _compose(TicketType.suggestion),
                  ),
              };
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _TopBar(
                    tab: tab,
                    stacked: box.maxWidth < kHubBarFoldBelow,
                    search: _SearchField(controller: _search, focusNode: _searchFocus),
                    onTab: _tab,
                    onNew: _compose,
                    onClose: widget.onClose,
                  ),
                  Expanded(child: body),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _myTickets(BuildContext context, {required bool stacked}) {
    final tickets = ref.watch(ticketsProvider).valueOrNull ?? const <SupportTicketRow>[];
    final queued = ref.watch(queuedReportsProvider).valueOrNull ?? const <FeedbackReport>[];
    final chosen = ref.watch(supportHubTicketProvider);
    final kind = ref.watch(supportHubComposeProvider);
    // What waits to be sent on top, so nothing typed seems to have vanished.
    final entries = <_Entry>[
      for (final r in queued) _Entry.report(r),
      for (final t in tickets) _Entry.ticket(t),
    ];
    _Entry? selected;
    for (final e in entries) {
      if (e.nonce == chosen) selected = e;
    }
    if (selected == null && !stacked && kind == null && entries.isNotEmpty) {
      selected = entries.firstWhere((e) => e.group == _Group.needsReply, orElse: () => entries.first);
    }
    final l10n = AppLocalizations.of(context)!;
    final list = _ListColumn(
      entries: entries,
      query: _search.text.trim().toLowerCase(),
      selected: kind == null ? selected?.nonce : null,
      stale: _stale ? ticketsStaleText(l10n, _stopped) : null,
      allClosed: _allClosed,
      onAllClosed: () => setState(() => _allClosed = true),
      onSelect: _select,
      onCompose: _compose,
    );
    final Widget center;
    if (kind != null) {
      center = SupportHubCompose(
        kind: kind,
        captureScreenshot: widget.captureScreenshot,
        onClose: widget.onClose,
      );
    } else if (selected == null) {
      center = _NothingChosen(hasAny: entries.isNotEmpty, onCompose: _compose);
    } else if (selected.ticket == null) {
      center = _WaitingReport(key: ValueKey('hub-report-${selected.nonce}'), report: selected.report!);
    } else {
      center = TicketDetailScreen(
        // A fresh page per ticket: a half-typed reply never leaks into another
        // conversation.
        key: ValueKey('hub-ticket-${selected.nonce}'),
        nonce: selected.nonce,
        embedded: true,
        hub: true,
        captureScreenshot: widget.captureScreenshot,
        onLeave: () => _select(null),
        onNewTicket: () => _compose(TicketType.support),
      );
    }
    if (stacked) {
      if (kind == null && selected == null) return list;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: ZestButton(
                key: const ValueKey('hub-back-to-list'),
                label: l10n.back,
                icon: LucideIcons.arrowLeft,
                variant: ZestButtonVariant.ghost,
                onPressed: () => _select(null),
              ),
            ),
          ),
          Expanded(child: center),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: 380, child: list),
        VerticalDivider(width: 1, thickness: 1, color: AppColors.v3BorderSubtle),
        Expanded(child: center),
      ],
    );
  }
}

/// The band over the hub: "Support", the three tabs, whether the desk answers,
/// the search, New, and the way back to the sessions. On a phone it folds into
/// two rows and the search under them.
class _TopBar extends ConsumerWidget {
  const _TopBar({
    required this.tab,
    required this.stacked,
    required this.search,
    required this.onTab,
    required this.onNew,
    required this.onClose,
  });

  final HubTab tab;
  final bool stacked;
  final Widget search;
  final ValueChanged<HubTab> onTab;
  final ValueChanged<TicketType> onNew;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final waiting = (ref.watch(ticketsProvider).valueOrNull ?? const <SupportTicketRow>[]).where(hubWaitsForYou).length;
    final title = Text(
      l10n.supportHubTitle,
      style: TextStyle(
        fontFamily: 'GeistSans',
        fontSize: 18,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
        color: AppColors.v3TextPrimary,
      ),
    );
    final tabs = [
      _Tab(
        key: const ValueKey('hub-tab-tickets'),
        label: l10n.ticketsTitle,
        count: waiting,
        selected: tab == HubTab.myTickets,
        onTap: () => onTab(HubTab.myTickets),
      ),
      _Tab(
        key: const ValueKey('hub-tab-known'),
        label: l10n.supportHubTabKnownIssues,
        selected: tab == HubTab.knownIssues,
        onTap: () => onTab(HubTab.knownIssues),
      ),
      _Tab(
        key: const ValueKey('hub-tab-ideas'),
        label: l10n.supportHubTabIdeas,
        selected: tab == HubTab.ideas,
        onTap: () => onTab(HubTab.ideas),
      ),
    ];
    final close = IconButton(
      key: const ValueKey('hub-close'),
      tooltip: '${l10n.close} (Esc)',
      onPressed: onClose,
      color: AppColors.v3TextSecondary,
      icon: const Icon(LucideIcons.x, size: 18),
    );
    final border = BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.v3BorderSubtle)));
    if (stacked) {
      return Container(
        decoration: border,
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                title,
                const SizedBox(width: 10),
                const Flexible(child: _Health(compact: true)),
                const Spacer(),
                _NewButton(onNew: onNew, compact: true),
                close,
              ],
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [for (final t in tabs) Padding(padding: const EdgeInsetsDirectional.only(end: 18), child: t)]),
            ),
            const SizedBox(height: 8),
            Padding(padding: const EdgeInsetsDirectional.only(end: 8), child: search),
          ],
        ),
      );
    }
    return Container(
      height: 58,
      decoration: border,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        children: [
          title,
          const SizedBox(width: 30),
          for (final t in tabs) ...[t, const SizedBox(width: 22)],
          const Spacer(),
          const Flexible(flex: 2, child: _Health(compact: false)),
          const SizedBox(width: 14),
          Flexible(flex: 3, child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 350), child: search)),
          const SizedBox(width: 14),
          _NewButton(onNew: onNew),
          const SizedBox(width: 10),
          Container(width: 1, height: 22, color: AppColors.v3BorderSubtle),
          const SizedBox(width: 6),
          close,
        ],
      ),
    );
  }
}

/// A tab of the top bar: its name, a count where something waits for the
/// person, and the accent line under the one showing.
class _Tab extends StatelessWidget {
  const _Tab({super.key, required this.label, required this.selected, required this.onTap, this.count = 0});

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: selected ? ZestTokens.brand : Colors.transparent, width: 2)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected ? AppColors.v3TextPrimary : AppColors.v3TextSecondary,
                  ),
                ),
                if (count > 0) ...[
                  const SizedBox(width: 7),
                  _CountBadge(count),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge(this.count);

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 18),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(color: AppColors.v3Warning, borderRadius: BorderRadius.circular(9)),
      child: Text(
        '$count',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.v3Background),
      ),
    );
  }
}

/// "+ New": Get help, Report a bug or Suggest an idea.
class _NewButton extends StatelessWidget {
  const _NewButton({required this.onNew, this.compact = false});

  final ValueChanged<TicketType> onNew;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    PopupMenuItem<TicketType> item(TicketType t, IconData icon, String label) => PopupMenuItem(
          key: ValueKey('hub-new-${t.wire}'),
          value: t,
          child: Row(
            children: [
              Icon(icon, size: 15, color: AppColors.v3TextSecondary),
              const SizedBox(width: 10),
              Text(label, style: const TextStyle(fontSize: 13)),
            ],
          ),
        );
    return PopupMenuButton<TicketType>(
      key: const ValueKey('hub-new'),
      tooltip: l10n.supportHubNew,
      onSelected: onNew,
      position: PopupMenuPosition.under,
      itemBuilder: (_) => [
        item(TicketType.support, LucideIcons.lifeBuoy, l10n.helpSupport),
        item(TicketType.bug, LucideIcons.bug, l10n.helpReportBug),
        item(TicketType.suggestion, LucideIcons.lightbulb, l10n.supportHubSuggestIdea),
      ],
      child: Container(
        height: 34,
        padding: EdgeInsets.symmetric(horizontal: compact ? 9 : 14),
        decoration: BoxDecoration(color: ZestTokens.brand, borderRadius: BorderRadius.circular(8)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.plus, size: 15, color: ZestTokens.onBrand),
            if (!compact) ...[
              const SizedBox(width: 6),
              Text(
                l10n.supportHubNew,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: ZestTokens.onBrand),
              ),
            ],
            const SizedBox(width: 6),
            Icon(LucideIcons.chevronDown, size: 14, color: ZestTokens.onBrand),
          ],
        ),
      ),
    );
  }
}

/// "Search tickets, known issues and ideas", / to get there.
class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.focusNode});

  final TextEditingController controller;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    OutlineInputBorder border(Color c) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: c),
        );
    return SizedBox(
      height: 36,
      child: TextField(
        key: const ValueKey('hub-search'),
        controller: controller,
        focusNode: focusNode,
        style: const TextStyle(fontSize: 13),
        textAlignVertical: TextAlignVertical.center,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: AppColors.v3Surface,
          hintText: l10n.supportHubSearchAll,
          hintStyle: TextStyle(fontSize: 13, color: AppColors.v3TextTertiary),
          prefixIcon: Icon(LucideIcons.search, size: 15, color: AppColors.v3TextTertiary),
          prefixIconConstraints: const BoxConstraints(minWidth: 34, minHeight: 34),
          suffixIcon: const Padding(
            padding: EdgeInsetsDirectional.only(end: 8),
            child: Align(widthFactor: 1, child: HubKbd('/')),
          ),
          suffixIconConstraints: const BoxConstraints(minHeight: 34),
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          border: border(AppColors.v3BorderDefault),
          enabledBorder: border(AppColors.v3BorderDefault),
          focusedBorder: border(AppColors.brandOrange),
        ),
      ),
    );
  }
}

/// Whether the desk can be reached, from the same check the Help panel's
/// footer makes. Where there is not room for the words, the dot says it and
/// the words are its tooltip.
class _Health extends ConsumerWidget {
  const _Health({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final String line;
    final Color dot;
    switch (ref.watch(cloudStatusProvider).valueOrNull) {
      case CloudStatus.ok:
        line = l10n.supportHubRepliesWithinDay;
        dot = AppColors.v3Success;
      case CloudStatus.degraded:
        line = l10n.supportHubHealthDown(l10n.helpStatusDegraded);
        dot = AppColors.v3Warning;
      case CloudStatus.unreachable:
        final failure = cloudNoAnswerNow();
        line = l10n.supportHubHealthDown(failure.label(l10n));
        dot = failure.onThisSide ? AppColors.v3Warning : AppColors.v3Error;
      case null:
        line = l10n.supportHubHealthChecking;
        dot = AppColors.v3TextTertiary;
    }
    final mark = Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
    );
    if (compact) {
      return Tooltip(
        message: line,
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: mark),
      );
    }
    return Row(
      key: const ValueKey('hub-health'),
      mainAxisSize: MainAxisSize.min,
      children: [
        mark,
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            line,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12.5, color: AppColors.v3TextSecondary),
          ),
        ),
      ],
    );
  }
}

/// My tickets: what this device sent, grouped by where it stands.
class _ListColumn extends ConsumerWidget {
  const _ListColumn({
    required this.entries,
    required this.query,
    required this.selected,
    required this.stale,
    required this.allClosed,
    required this.onAllClosed,
    required this.onSelect,
    required this.onCompose,
  });

  final List<_Entry> entries;
  final String query;
  final String? selected;

  /// Why what shows is what was read last, or null.
  final String? stale;
  final bool allClosed;
  final VoidCallback onAllClosed;
  final ValueChanged<String?> onSelect;
  final ValueChanged<TicketType> onCompose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final shown = [
      for (final e in entries)
        if (query.isEmpty || e.searchable.contains(query)) e,
    ];
    final groups = <_Group, List<_Entry>>{for (final g in _Group.values) g: []};
    for (final e in shown) {
      groups[e.group]!.add(e);
    }
    String name(_Group g) => switch (g) {
          _Group.needsReply => l10n.supportHubGroupNeedsReply,
          _Group.waiting => l10n.ticketAwaitingSupport,
          _Group.ideas => l10n.supportHubGroupIdeas,
          _Group.closed => l10n.ticketStatusClosed,
        };
    final children = <Widget>[
      if (stale != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
          child: HelpNoticeLine(icon: LucideIcons.wifiOff, text: stale!),
        ),
    ];
    for (final g in _Group.values) {
      final list = groups[g]!;
      if (list.isEmpty) continue;
      final hidden = g == _Group.closed && !allClosed && query.isEmpty ? list.length - kHubClosedShown : 0;
      children.add(_GroupHeader(key: ValueKey('hub-group-${g.name}'), label: name(g), count: list.length));
      for (final e in hidden > 0 ? list.take(kHubClosedShown) : list) {
        children.add(_Row(
          key: ValueKey('hub-row-${e.nonce}'),
          entry: e,
          selected: e.nonce == selected,
          onTap: () => onSelect(e.nonce),
        ));
      }
      if (hidden > 0) {
        children.add(Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              key: const ValueKey('hub-more-closed'),
              onPressed: onAllClosed,
              child: Text(l10n.supportHubShowMoreClosed(hidden), style: TextStyle(fontSize: 13, color: AppColors.v3TextPrimary)),
            ),
          ),
        ));
      }
      children.add(const SizedBox(height: 8));
    }
    if (shown.isEmpty) {
      children.add(Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              entries.isEmpty ? l10n.ticketsEmptyBody : l10n.supportHubNoMatches,
              key: const ValueKey('hub-list-empty'),
              style: TextStyle(fontSize: 12.5, height: 1.4, color: AppColors.v3TextSecondary),
            ),
          ],
        ),
      ));
    }
    return ListView(
      key: const ValueKey('hub-list'),
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 16),
      children: children,
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({super.key, required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      child: Row(
        children: [
          Flexible(
            child: Text(
              label.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 10.5, letterSpacing: 1.4, color: ZestTokens.textMuted),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(color: ZestTokens.surfaceChip, borderRadius: BorderRadius.circular(5)),
            child: Text('$count', style: TextStyle(fontSize: 10.5, color: ZestTokens.textSecondary)),
          ),
        ],
      ),
    );
  }
}

/// What a ticket's kind is called in a list: Bug, Help, Idea.
String hubKindName(AppLocalizations l10n, TicketType type) => switch (type) {
      TicketType.support => l10n.supportHubKindHelp,
      TicketType.bug => l10n.reportTypeBug,
      TicketType.suggestion => l10n.supportHubKindIdea,
    };

/// The second line of a row: the last words said on it, or where it stands.
String hubRowLine(AppLocalizations l10n, SupportTicketRow t) {
  final standing = t.standing;
  if (t.isClosed || t.isGone) {
    if (t.isGone) return l10n.ticketStatusGone;
    if (standing.closedReason == 'no_reply') return l10n.supportHubClosedNoReply;
    if (standing.state == 'fixed' && standing.stateVersion != null) return l10n.supportHubStateFixedIn(standing.stateVersion!);
    if (standing.state == 'shipped' && standing.stateVersion != null) return l10n.supportHubStateShippedIn(standing.stateVersion!);
    if (standing.closedReason == 'fixed') return l10n.supportHubClosedFixed;
    return l10n.ticketStatusClosed;
  }
  if (t.isRefused) return '${l10n.ticketStatusNotSent} · ${ticketNotSentCode(t).code}';
  if (t.isWaiting) return l10n.ticketStatusWaiting;
  if (t.ticketType == TicketType.suggestion && !hubWaitsForYou(t)) {
    final state = reportStateLabel(l10n, ReportState.fromWire(standing.state), version: standing.stateVersion);
    return '$state. ${l10n.supportHubPeopleWantThis(standing.votes)}';
  }
  final c = t.cachedConversation;
  final last = c == null || c.messages.isEmpty ? null : c.messages.last;
  if (last != null && last.id == (t.lastMessageId ?? last.id)) {
    return last.fromStaff ? l10n.supportHubSaidSupport(last.body) : l10n.supportHubSaidYou(last.body);
  }
  // An answer this device has not read yet: its words come when it is opened.
  if (t.lastMessageFrom == 'staff') return l10n.ticketReplyFromSupport;
  return l10n.supportHubSaidYou(c?.body ?? '');
}

/// One line of My tickets: a dot while an answer is unread, the subject and
/// when, the last words said, and what kind it is and who can see it.
class _Row extends ConsumerStatefulWidget {
  const _Row({super.key, required this.entry, required this.selected, required this.onTap});

  final _Entry entry;
  final bool selected;
  final VoidCallback onTap;

  @override
  ConsumerState<_Row> createState() => _RowState();
}

class _RowState extends ConsumerState<_Row> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final e = widget.entry;
    final t = e.ticket;
    final report = e.report;
    final type = e.type;
    final title = Redactable.freeText(t?.title ?? report!.threadTitle).displayIn(ref);
    final when = t?.lastActivity.toLocal() ?? report!.createdAt;
    final unread = t != null && (t.hasUnreadReply || (hubWaitsForYou(t) && t.awaiting == 'user'));
    final line = t == null ? l10n.ticketStatusWaiting : hubRowLine(l10n, t);
    final private = t?.isPrivate ?? false;
    final quiet = TextStyle(fontSize: 12, color: AppColors.v3TextTertiary);
    return Semantics(
      button: true,
      selected: widget.selected,
      label: title,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            margin: const EdgeInsets.only(bottom: 4),
            padding: const EdgeInsets.fromLTRB(10, 10, 12, 10),
            decoration: BoxDecoration(
              color: widget.selected
                  ? ZestTokens.surfaceRaised
                  : _hover
                      ? AppColors.v3Hover
                      : Colors.transparent,
              borderRadius: BorderRadius.circular(9),
              border: BorderDirectional(
                start: BorderSide(color: widget.selected ? ZestTokens.brand : Colors.transparent, width: 2),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 16,
                  child: unread
                      ? Padding(
                          padding: const EdgeInsets.only(top: 5),
                          child: Container(
                            key: const ValueKey('hub-unread'),
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(color: AppColors.v3Warning, shape: BoxShape.circle),
                          ),
                        )
                      : null,
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: AppColors.v3TextPrimary),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(ticketRelativeTime(l10n, when), style: quiet),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        Redactable.freeText(line).displayIn(ref),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12.5, color: AppColors.v3TextSecondary),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(ticketTypeIcon(type), size: 12, color: AppColors.v3TextTertiary),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              [
                                hubKindName(l10n, type),
                                if (t != null && t.number != null) ticketNumberLabel(t.number),
                                if (t != null) private ? l10n.supportHubPrivate : l10n.supportHubPublic,
                              ].join('  ·  '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: quiet,
                            ),
                          ),
                        ],
                      ),
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
}

/// The right with nothing to show: no ticket yet, or none chosen.
class _NothingChosen extends StatelessWidget {
  const _NothingChosen({required this.hasAny, required this.onCompose});

  final bool hasAny;
  final ValueChanged<TicketType> onCompose;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.inbox, size: 30, color: AppColors.v3TextTertiary),
            const SizedBox(height: 12),
            Text(
              hasAny ? l10n.ticketsTitle : l10n.ticketsEmptyTitle,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.v3TextPrimary),
            ),
            const SizedBox(height: 6),
            Text(
              hasAny ? l10n.supportHubPickOne : l10n.ticketsEmptyBody,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, height: 1.4, color: AppColors.v3TextSecondary),
            ),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                ZestButton(
                  key: const ValueKey('hub-start-help'),
                  label: l10n.helpSupport,
                  icon: LucideIcons.lifeBuoy,
                  onPressed: () => onCompose(TicketType.support),
                ),
                ZestButton(
                  key: const ValueKey('hub-start-bug'),
                  label: l10n.helpReportBug,
                  icon: LucideIcons.bug,
                  onPressed: () => onCompose(TicketType.bug),
                ),
                ZestButton(
                  key: const ValueKey('hub-start-idea'),
                  label: l10n.supportHubSuggestIdea,
                  icon: LucideIcons.lightbulb,
                  onPressed: () => onCompose(TicketType.suggestion),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A bug report or a suggestion that has not reached the server: what was
/// written, and that it goes by itself.
class _WaitingReport extends ConsumerStatefulWidget {
  const _WaitingReport({super.key, required this.report});

  final FeedbackReport report;

  @override
  ConsumerState<_WaitingReport> createState() => _WaitingReportState();
}

class _WaitingReportState extends ConsumerState<_WaitingReport> {
  bool _trying = false;

  Future<void> _tryNow() async {
    if (_trying) return;
    setState(() => _trying = true);
    try {
      await ref.read(feedbackServiceProvider).retryQueued();
    } catch (_) {/* stays waiting */}
    if (mounted) setState(() => _trying = false);
  }

  Future<void> _copy() async {
    final l10n = AppLocalizations.of(context)!;
    await Clipboard.setData(ClipboardData(text: widget.report.toClipboardText()));
    if (mounted) showTopSnackBar(context, l10n.reportCopied, isSuccess: true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final r = widget.report;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TicketChip(
            label: l10n.ticketStatusWaiting,
            ink: ZestTokens.textSecondary,
            fill: ZestTokens.surfaceChip,
            icon: LucideIcons.clock,
          ),
        ),
        const SizedBox(height: 8),
        RedactedText(
          Redactable.freeText(r.threadTitle),
          style: TextStyle(
            fontFamily: 'GeistSans',
            fontSize: 18,
            height: 1.3,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.18,
            color: AppColors.v3TextPrimary,
          ),
        ),
        const SizedBox(height: 14),
        HubMessage(
          who: l10n.ticketYou,
          when: r.createdAt,
          text: r.body,
          extraLabel: l10n.reportBugWhatExpected,
          extra: r.expected == null || r.expected!.trim().isEmpty ? null : r.expected,
        ),
        Text(
          l10n.ticketWaitingNotice,
          style: TextStyle(fontSize: 12.5, height: 1.4, color: AppColors.v3TextSecondary),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            ZestButton(
              key: const ValueKey('hub-report-try'),
              label: l10n.ticketTryNow,
              isLoading: _trying,
              onPressed: _tryNow,
            ),
            ZestButton(
              label: l10n.reportCopy,
              variant: ZestButtonVariant.ghost,
              icon: LucideIcons.copy,
              onPressed: _copy,
            ),
          ],
        ),
      ],
    );
  }
}
