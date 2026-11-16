import 'package:lucide_icons/lucide_icons.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zestssh/database/daos/connections_dao.dart' show ConnectionWithDetails;
import 'package:zestssh/database/database.dart' show Connection;
import 'package:zestssh/features/hosts/connect_as.dart';
import 'package:zestssh/features/hosts/connect_link.dart' show quickConnectLinkText;
import 'package:zestssh/features/hosts/quick_target.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/utils/host_search.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/button_spinner.dart';
import 'package:zestssh/utils/after_next_frame.dart';

/// Set to ask for the keyboard in the quick connect field (a keyboard's quick
/// connect key, Ctrl+T or Cmd+T): Home shows its list of hosts, and the
/// field, once it is on screen, takes the keyboard and sets this back.
final quickConnectFocusWanted = ValueNotifier<bool>(false);

/// The field at the top of a phone's Hosts: what is typed filters the hosts
/// below it (connectionSearchQueryProvider), and Go connects: to the saved
/// host whose name it is, or to `user@host:port`, read as everywhere it is
/// typed ([parseQuickTarget]).
class QuickConnectBar extends ConsumerStatefulWidget {
  const QuickConnectBar({super.key});

  @override
  ConsumerState<QuickConnectBar> createState() => _QuickConnectBarState();
}

class _QuickConnectBarState extends ConsumerState<QuickConnectBar> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _isConnecting = false;

  @override
  void initState() {
    super.initState();
    // A quick connect link's host: typed in, for the person to connect or
    // not. One that came before this bar was on screen, and one that comes
    // while it is.
    quickConnectLinkText.addListener(_takeLinkText);
    WidgetsBinding.instance.addPostFrameCallback((_) => _takeLinkText());
    // The keyboard asked for in the field: asked before it was on screen
    // (from a terminal, or from behind another tab), and while it is.
    quickConnectFocusWanted.addListener(_takeFocusAsk);
    WidgetsBinding.instance.addPostFrameCallback((_) => _takeFocusAsk());
  }

  void _takeFocusAsk() {
    if (!quickConnectFocusWanted.value || !mounted) return;
    quickConnectFocusWanted.value = false;
    afterNextFrame((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  void _takeLinkText() {
    final typed = quickConnectLinkText.value;
    if (typed == null || !mounted) return;
    quickConnectLinkText.value = null;
    _controller.value = TextEditingValue(text: typed, selection: TextSelection.collapsed(offset: typed.length));
    // Once the list of hosts is on screen (it may be coming from behind
    // another tab).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  /// What is typed, as the hosts below are filtered by.
  void _typed(String text) => ref.read(connectionSearchQueryProvider.notifier).state = text;

  @override
  void dispose() {
    quickConnectLinkText.removeListener(_takeLinkText);
    quickConnectFocusWanted.removeListener(_takeFocusAsk);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // The search's emptied from elsewhere (leaving Hosts ends it): so is the
    // field.
    ref.listen<String>(connectionSearchQueryProvider, (_, query) {
      if (query.isEmpty && _controller.text.isNotEmpty) _controller.clear();
    });
    // The phone lists' search field (PhoneSearchField): its fill, radius,
    // hairline, accent focus, text sizes and height; Go is a quiet arrow in
    // the accent's ink with a full 44 target (3.0 UI review: a 36 orange
    // block in a field of its own style).
    OutlineInputBorder edge(Color color, [double width = 1]) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: color, width: width),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
      child: TextField(
        key: const ValueKey('quick-connect-bar-field'),
        controller: _controller,
        focusNode: _focus,
        onChanged: _typed,
        style: TextStyle(fontSize: 15, color: ZestTokens.textPrimary),
        decoration: InputDecoration(
          hintText: l10n.phoneHostsSearchHint,
          hintStyle: TextStyle(fontSize: 15, color: ZestTokens.textTertiary),
          // A search, as a computer's field over its hosts has it (4.0): it
          // finds hosts first, and connects to user@host:port too.
          prefixIcon: Icon(LucideIcons.search, size: 18, color: ZestTokens.textTertiary),
          suffixIcon: IconButton(
            key: const ValueKey('quick-connect-go'),
            tooltip: l10n.commonConnect,
            onPressed: _isConnecting ? null : _quickConnect,
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            icon: _isConnecting
                ? const SizedBox(width: 16, height: 16, child: ButtonSpinner())
                : Icon(LucideIcons.arrowRight, size: 18, color: ZestTokens.brandInk),
          ),
          isDense: true,
          filled: true,
          fillColor: AppColors.surface,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          border: edge(AppColors.v3BorderSubtle),
          enabledBorder: edge(AppColors.v3BorderSubtle),
          focusedBorder: edge(AppColors.brandOrange),
        ),
        keyboardType: TextInputType.url,
        textInputAction: TextInputAction.go,
        onSubmitted: (_) => _quickConnect(),
      ),
    );
  }

  /// A saved host named as typed ([savedHostNamedAs]). Null for an address
  /// to dial.
  Future<Connection?> _savedNamed(String input) async {
    final hosts = ref.read(connectionsWithDetailsProvider).valueOrNull ?? const [];
    return savedHostNamedAs(hosts, input)?.connection;
  }

  Future<void> _quickConnect() async {
    final input = _controller.text.trim();
    if (input.isEmpty) return;
    final l10n = AppLocalizations.of(context)!;

    // The name of a saved host: that host, as a tap on it connects.
    final named = await _savedNamed(input);
    if (named != null) {
      if (!mounted) return;
      if (named.protocol == 'telnet' && !await _telnetAnyway(l10n)) return;
      if (!ref.read(isProProvider) &&
          ref.read(activeSessionsProvider.notifier).occupiedSessionSlots >= freeSessionLimit) {
        _showFreeLimit(l10n);
        return;
      }
      final sessionId = ref.read(activeSessionsProvider.notifier).startSession(named);
      if (!mounted) return;
      if (sessionId == null) return _showFreeLimit(l10n);
      _clear();
      context.push('/terminal/$sessionId');
      return;
    }

    // Read as user@host:port everywhere it is typed (parseQuickTarget); with
    // no port typed, the one Settings gives new connections.
    if (!mounted) return;
    final target = parseQuickTarget(input, defaultPort: ref.read(defaultPortProvider));
    if (target == null) {
      showTopSnackBar(context, l10n.quickConnectV3InvalidHostFormat, isError: true);
      return;
    }
    final user = target.user;

    setState(() => _isConnecting = true);
    try {
      // ── Free tier: limit concurrent sessions ──
      // Slots genuinely held: a session being closed frees its slot at once,
      // so opening another need not wait out the close delay (see
      // [ActiveSessionsNotifier.occupiedSessionSlots]).
      if (!ref.read(isProProvider) &&
          ref.read(activeSessionsProvider.notifier).occupiedSessionSlots >= freeSessionLimit) {
        _showFreeLimit(l10n);
        return;
      }

      // A key whose user is the one typed, where there is one.
      String? keyOfUser;
      if (user != null) {
        final identities = await ref.read(identitiesDaoProvider).getAll();
        keyOfUser = identities.where((i) => i.username == user).firstOrNull?.id;
      }

      // A host saved with this address and port is connected to, not saved
      // again; a new one is saved, signed in with that key.
      final dao = ref.read(connectionsDaoProvider);
      final saved = await dao.findByHostPort(target.host, target.port);
      final String? sessionId;
      if (saved == null) {
        final connectionId = await ref.read(connectionCrudProvider).create(
              label: input,
              host: target.host,
              port: target.port,
              identityId: keyOfUser,
            );
        final connection = await dao.getById(connectionId);
        if (connection == null || !mounted) return;
        sessionId = ref.read(activeSessionsProvider.notifier).startSession(connection, usernameOverride: user);
      } else {
        final open = await _sessionToSaved(saved, target, keyOfUser);
        if (!mounted) return;
        // A host that nothing encrypts (Telnet) is asked about first, in the
        // host list's words; it was connected to with no word.
        if (open.host.protocol == 'telnet' && !await _telnetAnyway(l10n)) return;
        // (Its last use is stamped by its session once it is connected.)
        sessionId = ref
            .read(activeSessionsProvider.notifier)
            .startSession(open.host, usernameOverride: open.user, asAccount: open.account);
      }
      if (!mounted) return;
      if (sessionId == null) {
        _showFreeLimit(l10n);
        return;
      }
      // startSession is non-blocking: the terminal shows it connecting.
      _clear();
      context.push('/terminal/$sessionId');
    } catch (e) {
      if (mounted) {
        showTopSnackBar(context, l10n.quickConnectNotStarted, isError: true, details: '$e');
      }
    } finally {
      if (mounted) setState(() => _isConnecting = false);
    }
  }

  /// Done with what was typed: the field and the filter of the hosts emptied.
  void _clear() {
    _controller.clear();
    _typed('');
  }

  /// How a session to the saved host [saved] is opened as the user typed:
  /// signed in with its own account where no user is typed or the one typed
  /// is its key's (or it has no key); with one of its other accounts whose
  /// user it is (3.0, accounts per host); else as the user typed, to its
  /// address as a host not saved, with [keyOfUser] (a key of that user)
  /// where there is one, and not with the host's own key, which is another
  /// account's. A Telnet host is the host itself whatever user is typed:
  /// nothing signs in to it but what is typed in it (it was reached over
  /// SSH, on its Telnet port).
  Future<({Connection host, String? user, String? account})> _sessionToSaved(
      Connection saved, QuickTarget target, String? keyOfUser) async {
    final user = target.user;
    if (user == null || saved.protocol == 'telnet') return (host: saved, user: user, account: null);
    final own = saved.identityId == null ? null : await ref.read(identitiesDaoProvider).getById(saved.identityId!);
    if (own == null || own.username == user) return (host: saved, user: user, account: null);
    final other = (await hostAccountChoicesNow(ref, saved.id)).where((a) => a.username == user).firstOrNull;
    if (other != null) return (host: saved, user: null, account: other.id);
    return (host: quickConnectionOf(target).copyWith(identityId: Value(keyOfUser)), user: user, account: null);
  }

  /// Asked before a host that nothing encrypts (Telnet) is connected to, in
  /// the host list's words: true for "connect anyway".
  Future<bool> _telnetAnyway(AppLocalizations l10n) async {
    // It exposes what is typed (the dialog rules, 3.4): red, and the risk in
    // its amber sentence.
    final proceed = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.homeTelnetWarningTitle,
      body: '',
      warning: l10n.homeTelnetWarningBody,
      confirmLabel: l10n.homeTelnetConnectAnyway,
      // Enter does not connect: the safe choice stands (L10).
      autofocusConfirm: false,
    );
    return proceed == true && mounted;
  }

  /// The free plan's limit on sessions open at once, with the way to more.
  void _showFreeLimit(AppLocalizations l10n) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showMaterialBanner(
      MaterialBanner(
        content: Text(l10n.hostsHomeFreeTierLimit),
        actions: [
          TextButton(
            onPressed: () {
              messenger.hideCurrentMaterialBanner();
              context.push(Routes.upgrade);
            },
            child: Text(l10n.upgrade),
          ),
          TextButton(
            onPressed: messenger.hideCurrentMaterialBanner,
            child: Text(l10n.desktopDismiss),
          ),
        ],
      ),
    );
  }
}

/// The saved host that what was typed in the bar names, or null to dial it
/// as an address. What has a user, a port or a dot in it is an address. A
/// host whose name, or else whose address, is exactly what was typed
/// (ignoring case) is that host, when only one is; else a host whose name,
/// address, user or group has it in it, when only one does. Two or more
/// hosts that could be meant are none: "root" or "pi" opened whichever came
/// first.
ConnectionWithDetails? savedHostNamedAs(List<ConnectionWithDetails> hosts, String input) {
  final typed = input.trim().toLowerCase();
  if (typed.isEmpty || typed.contains('@') || typed.contains(':') || typed.contains('.')) return null;
  ConnectionWithDetails? onlyOne(Iterable<ConnectionWithDetails> found) =>
      found.length == 1 ? found.single : null;
  final byName = hosts.where((h) => h.connection.label.toLowerCase() == typed).toList();
  if (byName.isNotEmpty) return onlyOne(byName);
  final byAddress = hosts.where((h) => h.connection.host.toLowerCase() == typed).toList();
  if (byAddress.isNotEmpty) return onlyOne(byAddress);
  return onlyOne(hosts.where((h) => hostMatchesQuery(h, typed)).toList());
}
