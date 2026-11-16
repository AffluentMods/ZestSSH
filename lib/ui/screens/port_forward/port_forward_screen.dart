import 'dart:io';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import 'package:zestssh/database/database.dart' as db;
import 'package:zestssh/features/orchards/move/item_transfer.dart' show TransferKinds;
import 'package:zestssh/features/orchards/move/move_copy_menu.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/services/port_forward_messages.dart'
    show forwardStartFailureReport, forwardStartFailureSentence, runningForwardName;
import 'package:zestssh/services/port_forward_service.dart';
import 'package:zestssh/ui/screens/port_forward/network_bind_confirm.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_empty_state.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/ui/widgets/recording_masked_field.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/utils/byte_size.dart';
import 'package:zestssh/utils/platform_utils.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/phone_list.dart' show PhonePageColumn;
import 'package:zestssh/ui/widgets/zest_field.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';

/// [PortForward.description] with its addresses in their display form
/// (recording mode). The service composes the sentence; only the host parts
/// identify anything, so each is swapped for its masked form on a whole-token
/// boundary (longest first, so a fake never gets re-masked) and the arrows,
/// ports and wording survive.
String _describeForDisplay(PortForward forward, WidgetRef ref) {
  var text = forward.description;
  final hosts = {forward.bindAddress, forward.remoteHost}
      .where((h) => h.trim().isNotEmpty)
      .toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final host in hosts) {
    final shown = Redactable.address(host).displayIn(ref);
    if (shown == host) continue;
    text = text.replaceAll(
      RegExp('(?<![A-Za-z0-9.-])${RegExp.escape(host)}(?![A-Za-z0-9.-])'),
      shown,
    );
  }
  return text;
}

/// Show the adaptive port-forward editor.
///
/// Full-screen page on mobile, dialog on desktop. Returns a
/// [PortForwardResult] or `null` if cancelled.
///
/// [onDelete], editing a rule on a phone or a tablet: the rule's Delete,
/// which is on its own page there and not on its row in the list (3.0 quick
/// wins). It asks first and says whether the rule went; the page closes
/// when it did.
///
/// [movable], editing a saved rule on a phone or a tablet: its page has the
/// rule's Move or copy (4.0); moved, the page closes with nothing to save.
Future<PortForwardResult?> showPortForwardEditor(
  BuildContext context, {
  PortForwardResult? initial,
  Future<bool> Function()? onDelete,
  bool movable = false,
}) {
  if (isTouchLayout) {
    return Navigator.of(context).push<PortForwardResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _AddForwardPage(
          initial: initial,
          onDelete: initial == null ? null : onDelete,
          movable: movable && initial != null,
        ),
      ),
    );
  }
  final dialog = GlobalKey<_AddForwardDialogState>();
  return showZestModal<PortForwardResult>(
    context: context,
    size: ZestModalSize.standard,
    // Enter adds (or saves) it, as its main button does.
    onSubmit: () => dialog.currentState?.submit(),
    child: _AddForwardDialog(key: dialog, initial: initial),
  );
}

/// Result from the port-forward editor.
class PortForwardResult {
  final String id;
  final String type;
  final String bindAddress;
  final int bindPort;
  final String remoteHost;
  final int remotePort;
  final bool autoStart;
  final String? label;

  const PortForwardResult({
    required this.id,
    required this.type,
    required this.bindAddress,
    required this.bindPort,
    required this.remoteHost,
    required this.remotePort,
    required this.autoStart,
    this.label,
  });
}

/// Port forwarding management screen.
///
/// Allows creating, starting, and stopping local and remote
/// port forwards on an active SSH connection. Rules are persisted
/// to the database and survive app restarts.
class PortForwardScreen extends ConsumerStatefulWidget {
  final PortForwardService portForwardService;
  final String connectionLabel;

  /// Connection ID for persisting port forward rules.
  final String? connectionId;

  const PortForwardScreen({
    super.key,
    required this.portForwardService,
    required this.connectionLabel,
    this.connectionId,
  });

  @override
  ConsumerState<PortForwardScreen> createState() => _PortForwardScreenState();
}

class _PortForwardScreenState extends ConsumerState<PortForwardScreen> {
  final List<PortForward> _forwards = [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadSavedRules();
  }

  /// Load persisted port forward rules from the database.
  Future<void> _loadSavedRules() async {
    if (widget.connectionId == null) {
      setState(() => _loaded = true);
      return;
    }

    final dao = ref.read(portForwardRulesDaoProvider);
    final rules = await dao.getByConnection(widget.connectionId!);

    final forwards = rules.map((r) => PortForward(
          id: r.id,
          type: r.type == 'remote'
              ? PortForwardType.remote
              : r.type == 'dynamic'
                  ? PortForwardType.dynamic
                  : PortForwardType.local,
          bindAddress: r.bindAddress,
          bindPort: r.bindPort,
          remoteHost: r.remoteHost,
          remotePort: r.remotePort,
          label: r.label,
          autoStart: r.autoStart,
        ));

    if (!mounted) return;
    setState(() {
      _forwards.addAll(forwards);
      _loaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.portForwardTitle, style: const TextStyle(fontSize: 16)),
            RedactedText(Redactable.host(widget.connectionLabel),
                style: TextStyle(
                    fontSize: 12, color: AppColors.textSecondary)),
          ],
        ),
        leading: IconButton(
          tooltip: AppLocalizations.of(context)!.close,
          icon: const Icon(LucideIcons.x),
          onPressed: () => context.pop(),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.icon(
              onPressed: _addForward,
              icon: const Icon(LucideIcons.plus, size: 18),
              label: Text(l10n.portForwardAdd),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.orange,
                foregroundColor: AppColors.onBrand(AppColors.orange),
                padding: const EdgeInsets.symmetric(horizontal: 16),
              ),
            ),
          ),
        ],
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : _forwards.isEmpty
              ? _buildEmptyState()
              : Column(
                  children: [
                    if (Platform.isIOS)
                      Container(
                        width: double.infinity,
                        margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: AppColors.warning.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: AppColors.warning.withValues(alpha: 0.3),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(LucideIcons.info,
                                size: 16, color: AppColors.warning),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                l10n.portForwardIosBackgroundWarning,
                                style: TextStyle(
                                    fontSize: 12, color: AppColors.warning),
                              ),
                            ),
                          ],
                        ),
                      ),
                    Expanded(child: _buildForwardList()),
                  ],
                ),
    );
  }

  Widget _buildEmptyState() {
    final l10n = AppLocalizations.of(context)!;
    return ZestEmptyState(
      icon: LucideIcons.arrowLeftRight,
      title: l10n.portForwardNone,
      message: l10n.portForwardNoneDesc,
      actionLabel: l10n.portForwardAdd,
      onAction: _addForward,
    );
  }

  IconData _iconForType(PortForwardType type) {
    switch (type) {
      case PortForwardType.local:
        return LucideIcons.arrowRight;
      case PortForwardType.remote:
        return LucideIcons.arrowLeft;
      case PortForwardType.dynamic:
        return LucideIcons.globe;
    }
  }

  /// Service-TYPE label for a forward (what kind of tunnel it is), kept
  /// deliberately distinct from its DIRECTION. Direction is carried by
  /// [PortForward.description] (the concrete `source → destination`
  /// endpoints), so this slot never repeats a direction. Previously the
  /// local/remote cases returned direction strings ("Local → Remote") whose
  /// words collided with the "Local"/"Remote" service-type names, while the
  /// dynamic case returned a type name - an inconsistent, ambiguous mix.
  String _subtitleForType(PortForwardType type) {
    final l10n = AppLocalizations.of(context)!;
    switch (type) {
      case PortForwardType.local:
        return l10n.portForwardServiceLocal;
      case PortForwardType.remote:
        return l10n.portForwardServiceRemote;
      case PortForwardType.dynamic:
        return l10n.portForwardServiceSocks;
    }
  }

  Widget _buildForwardList() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: _forwards.length,
      itemBuilder: (context, index) {
        final forward = _forwards[index];
        final l10n = AppLocalizations.of(context)!;
        final isActive = widget.portForwardService.isActive(forward.id);

        // Show extra info for active SOCKS5 proxies
        String typeLabel = _subtitleForType(forward.type);
        if (isActive && forward.type == PortForwardType.dynamic) {
          final proxy =
              widget.portForwardService.getSocks5Server(forward.id);
          if (proxy != null) {
            final conns = proxy.activeConnections;
            typeLabel += ' \u2022 ${l10n.portForwardConnections(conns)} \u2022 ${formatByteSize(proxy.bytesTransferred)}';
          }
        }

        final hasLabel = forward.label != null && forward.label!.isNotEmpty;
        // Recording mode: a nickname may embed a host; the description always
        // embeds the addresses.
        final description = _describeForDisplay(forward, ref);
        final title = hasLabel
            ? Redactable.freeText(forward.label!).displayIn(ref)
            : description;

        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _editForward(forward, index),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  // Status indicator
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: (isActive ? AppColors.success : AppColors.textSecondary)
                          .withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      _iconForType(forward.type),
                      size: 18,
                      color: isActive ? AppColors.success : AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Text content
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                        const SizedBox(height: 2),
                        if (hasLabel) ...[
                          Text(
                            description,
                            style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                          const SizedBox(height: 2),
                        ],
                        Row(
                          children: [
                            Text(
                              typeLabel,
                              style: TextStyle(
                                fontSize: 11,
                                color: isActive ? AppColors.success : AppColors.textSecondary,
                              ),
                            ),
                            // Starts by itself: plain text on a phone and a
                            // tablet (a chip is for what needs someone).
                            if (forward.autoStart && isTouchLayout)
                              Text(
                                ' · ${l10n.portForwardAuto}',
                                style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
                              )
                            else if (forward.autoStart) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                decoration: BoxDecoration(
                                  color: AppColors.orange.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  l10n.portForwardAuto,
                                  style: TextStyle(fontSize: 10, color: AppColors.accentInk),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Action buttons
                  IconButton(
                    icon: Icon(
                      isActive ? LucideIcons.stopCircle : LucideIcons.playCircle,
                      color: isActive ? AppColors.error : AppColors.success,
                    ),
                    tooltip: isActive ? l10n.portForwardStop : l10n.portForwardStart,
                    onPressed: () => _toggleForward(forward),
                    visualDensity: VisualDensity.compact,
                  ),
                  // A phone's and a tablet's Delete is on the forward's own
                  // page (tap the row), not on its row (3.0).
                  if (!isTouchLayout)
                    IconButton(
                      icon: const Icon(LucideIcons.trash2, size: 20),
                      tooltip: l10n.delete,
                      onPressed: () => _removeForward(forward),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  PortForwardResult _toResult(PortForward f) => PortForwardResult(
        id: f.id,
        type: f.type == PortForwardType.remote
            ? 'remote'
            : f.type == PortForwardType.dynamic
                ? 'dynamic'
                : 'local',
        bindAddress: f.bindAddress,
        bindPort: f.bindPort,
        remoteHost: f.remoteHost,
        remotePort: f.remotePort,
        autoStart: f.autoStart,
        label: f.label,
      );

  PortForward _fromResult(PortForwardResult r) => PortForward(
        id: r.id,
        type: r.type == 'remote'
            ? PortForwardType.remote
            : r.type == 'dynamic'
                ? PortForwardType.dynamic
                : PortForwardType.local,
        bindAddress: r.bindAddress,
        bindPort: r.bindPort,
        remoteHost: r.remoteHost,
        remotePort: r.remotePort,
        autoStart: r.autoStart,
        label: r.label,
      );

  /// SharedPreferences key for the one-time iOS port forward intro dialog.
  static const _iosPortForwardIntroKey = 'ios_port_forward_intro_shown';

  Future<void> _addForward() async {
    // On iOS, show a one-time informational dialog before the first port forward
    if (Platform.isIOS) {
      await _maybeShowIosPortForwardIntro();
    }
    if (!mounted) return;

    final result = await showPortForwardEditor(context);

    if (result != null) {
      final added = _fromResult(result);
      // One that other devices on the network can reach: asked first.
      if (!mounted || !await confirmNetworkBind(context,
              listensOn: forwardListensOn(added.type, added.bindAddress), port: added.bindPort)) {
        return;
      }
      if (!mounted) return;
      setState(() => _forwards.add(added));

      // Persist to database
      if (widget.connectionId != null) {
        _persistRule(_fromResult(result));
      }
    }
  }

  /// Show a one-time dialog on iOS explaining backgrounding limitations
  /// for port forwards. Only shown once per device.
  Future<void> _maybeShowIosPortForwardIntro() async {
    final prefs = ref.read(sharedPreferencesProvider);
    final shown = prefs.getBool(_iosPortForwardIntroKey) ?? false;
    if (shown) return;

    final l10n = AppLocalizations.of(context)!;
    // Said with the app's own notice (a plain dialog built here): Got it,
    // or Learn more, which opens the page on running in the background.
    final gotIt = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.info,
      title: l10n.portForwardIosIntroTitle,
      body: l10n.pfIosIntroBodyNoMosh,
      confirmLabel: l10n.portForwardGotIt,
      cancelLabel: l10n.portForwardLearnMore,
    );
    if (gotIt == false && mounted) context.push(Routes.iosBackgrounding);

    await prefs.setBool(_iosPortForwardIntroKey, true);
  }

  Future<void> _editForward(PortForward forward, int index) async {
    final result = await showPortForwardEditor(
      context,
      initial: _toResult(forward),
      // On a phone and a tablet, Delete is on this page: asked first.
      onDelete: () => _confirmRemoveForward(forward),
    );

    if (result != null) {
      final edited = _fromResult(result);
      // One that other devices on the network can reach, where it did not
      // listen so before: asked first.
      if (!mounted ||
          !await confirmNetworkBind(context,
              listensOn: forwardListensOn(edited.type, edited.bindAddress),
              port: edited.bindPort,
              before: forwardListensOn(forward.type, forward.bindAddress))) {
        return;
      }
      // Stop old forward if active
      if (widget.portForwardService.isActive(forward.id)) {
        await widget.portForwardService.stopForward(forward.id);
      }
      final updated = edited;
      if (!mounted) return;
      setState(() => _forwards[index] = updated);

      // Update in database
      if (widget.connectionId != null) {
        _persistRule(updated, isUpdate: true);
      }
    }
  }

  Future<void> _persistRule(PortForward result, {bool isUpdate = false}) async {
    final dao = ref.read(portForwardRulesDaoProvider);
    final companion = db.PortForwardRulesCompanion(
      id: Value(result.id),
      connectionId: Value(widget.connectionId!),
      type: Value(result.type == PortForwardType.remote
          ? 'remote'
          : result.type == PortForwardType.dynamic
              ? 'dynamic'
              : 'local'),
      bindAddress: Value(result.bindAddress),
      bindPort: Value(result.bindPort),
      remoteHost: Value(result.remoteHost),
      remotePort: Value(result.remotePort),
      autoStart: Value(result.autoStart),
      label: Value(result.label),
      createdAt: Value(DateTime.now()),
    );

    if (isUpdate) {
      await dao.updateRule(companion);
    } else {
      await dao.insertRule(companion);
    }
  }

  Future<void> _toggleForward(PortForward forward) async {
    final isActive = widget.portForwardService.isActive(forward.id);

    try {
      if (isActive) {
        await widget.portForwardService.stopForward(forward.id);
      } else {
        await widget.portForwardService.startForward(forward);
      }
      if (mounted) setState(() {}); // Refresh UI
    } catch (e) {
      // Why, as the computer's forwards say it, with the details to copy
      // (22 October 2026: it said only "Failed to update port forward").
      if (mounted) {
        final t = AppLocalizations.of(context)!;
        final name = runningForwardName(forward);
        showTopSnackBar(
          context,
          isActive ? t.pfSessionStopFailed(name) : t.pfSessionStartFailed(name, forwardStartFailureSentence(t, e, forward.bindPort)),
          isError: true,
          details: forwardStartFailureReport(forward, e),
        );
      }
    }
  }

  /// Delete from the forward's own page (a phone's and a tablet's): asked
  /// first, as the list of every host's forwards asks. Whether it went.
  Future<bool> _confirmRemoveForward(PortForward forward) async {
    final l10n = AppLocalizations.of(context)!;
    final name = forward.label != null && forward.label!.isNotEmpty
        ? forward.label!
        : '${forward.bindAddress}:${forward.bindPort}';
    final confirmed = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.homeDeletePortForward,
      body: l10n.homeDeletePortForwardMsg(name),
      confirmLabel: l10n.delete,
    );
    if (confirmed != true || !mounted) return false;
    await _removeForward(forward);
    return true;
  }

  Future<void> _removeForward(PortForward forward) async {
    if (widget.portForwardService.isActive(forward.id)) {
      await widget.portForwardService.stopForward(forward.id);
    }
    if (!mounted) return;
    setState(() => _forwards.remove(forward));

    // Remove from database
    if (widget.connectionId != null) {
      final dao = ref.read(portForwardRulesDaoProvider);
      await dao.deleteRule(forward.id);
    }
  }

  @override
  void dispose() {
    super.dispose();
  }
}

// ── Shared form body ────────────────────────────────────────────

/// Builds the port-forward form fields used by both the mobile
/// full-screen page and the desktop dialog.
class _PortForwardFormBody extends StatelessWidget {
  final PortForwardResult? initial;
  final PortForwardType type;
  final ValueChanged<PortForwardType> onTypeChanged;
  final TextEditingController labelController;
  final TextEditingController bindAddressController;
  final TextEditingController bindPortController;
  final TextEditingController remoteHostController;
  final TextEditingController remotePortController;
  final bool autoStart;
  final ValueChanged<bool> onAutoStartChanged;
  final VoidCallback Function(String preset) onPreset;

  /// A phone's and a tablet's page: the fields in the app's own field (a
  /// name cell beside its value, as the host editor and a computer's port
  /// forwarding have them) and its switch; a computer's dialog keeps the
  /// form it has.
  final bool touch;

  const _PortForwardFormBody({
    required this.initial,
    required this.type,
    required this.onTypeChanged,
    required this.labelController,
    required this.bindAddressController,
    required this.bindPortController,
    required this.remoteHostController,
    required this.remotePortController,
    required this.autoStart,
    required this.onAutoStartChanged,
    required this.onPreset,
    this.touch = false,
  });

  bool get _isDynamic => type == PortForwardType.dynamic;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isEditing = initial != null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Presets (only for new rules)
        if (!isEditing) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              // A browser's window, as the app's Web server host icon draws
              // it (the globe is SOCKS's, beside it; a translate icon stood
              // here: found on a Pixel 3a).
              ActionChip(
                key: const ValueKey('pf-preset-web'),
                avatar: const Icon(LucideIcons.appWindow, size: 16),
                label: Text(l10n.portForwardWeb),
                onPressed: onPreset('web'),
              ),
              ActionChip(
                avatar: const Icon(LucideIcons.hardDrive, size: 16),
                label: Text(l10n.portForwardDatabase),
                onPressed: onPreset('database'),
              ),
              ActionChip(
                avatar: const Icon(LucideIcons.globe, size: 16),
                label: Text(l10n.portForwardSocks),
                onPressed: onPreset('socks'),
              ),
            ],
          ),
          const SizedBox(height: 16),
        ],

        // Type selector
        SegmentedButton<PortForwardType>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(
              value: PortForwardType.local,
              icon: const Icon(LucideIcons.arrowRight, size: 16),
              label: Text(l10n.portForwardLocal),
            ),
            ButtonSegment(
              value: PortForwardType.remote,
              icon: const Icon(LucideIcons.arrowLeft, size: 16),
              label: Text(l10n.portForwardRemote),
            ),
            ButtonSegment(
              value: PortForwardType.dynamic,
              icon: const Icon(LucideIcons.globe, size: 16),
              label: Text(l10n.portForwardSocks5),
            ),
          ],
          selected: {type},
          onSelectionChanged: (s) => onTypeChanged(s.first),
        ),
        const SizedBox(height: 20),

        if (touch)
          _touchFields(context, l10n)
        // A computer's dialog: the form it has, as it was.
        else ...[
        // Nickname
        TextFormField(
          controller: labelController,
          decoration: InputDecoration(
            labelText: l10n.portForwardNicknameOptional,
            hintText: l10n.portForwardNicknameHint,
          ),
          textCapitalization: TextCapitalization.words,
        ),
        const SizedBox(height: 16),

        // Bind port
        TextFormField(
          controller: bindPortController,
          decoration: InputDecoration(
            labelText:
                _isDynamic ? l10n.portForwardSocksPort : l10n.portForwardSourcePort,
            hintText: _isDynamic ? '1080' : '8080',
          ),
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          validator: (v) {
            if (v == null || v.isEmpty) return l10n.required;
            final port = int.tryParse(v);
            if (port == null || port < 1 || port > 65535) {
              return l10n.portForwardPortInvalid;
            }
            return null;
          },
        ),

        // Remote host & port - local/remote only. The remote host and the bind
        // address are identifiers: while recording they render masked and
        // read-only (the required check still runs on the real value).
        if (!_isDynamic) ...[
          const SizedBox(height: 16),
          RecordingMaskedFormField(
            controller: remoteHostController,
            mask: (v) => Redactable.address(v).display,
            decoration: InputDecoration(
              labelText: l10n.portForwardDestinationHost,
              hintText: l10n.portForwardRemoteHostHint,
            ),
            validate: () =>
                remoteHostController.text.isEmpty ? l10n.required : null,
            child: TextFormField(
              controller: remoteHostController,
              decoration: InputDecoration(
                labelText: l10n.portForwardDestinationHost,
                hintText: l10n.portForwardRemoteHostHint,
              ),
              validator: (v) =>
                  v == null || v.isEmpty ? l10n.required : null,
            ),
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: remotePortController,
            decoration: InputDecoration(
              labelText: l10n.portForwardDestinationPort,
              hintText: l10n.portForwardRemotePortHint,
            ),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            validator: (v) {
              if (v == null || v.isEmpty) return l10n.required;
              final port = int.tryParse(v);
              if (port == null || port < 1 || port > 65535) {
                return l10n.portForwardPortInvalid;
              }
              return null;
            },
          ),
        ],

        const SizedBox(height: 16),

        // Bind address (advanced)
        RecordingMaskedFormField(
          controller: bindAddressController,
          mask: (v) => Redactable.address(v).display,
          decoration: InputDecoration(
            labelText: l10n.portForwardBindAddress,
            hintText: '127.0.0.1',
            helperText: l10n.portForwardBindAddressHelper,
            helperMaxLines: 2,
          ),
          child: TextFormField(
            controller: bindAddressController,
            decoration: InputDecoration(
              labelText: l10n.portForwardBindAddress,
              hintText: '127.0.0.1',
              helperText: l10n.portForwardBindAddressHelper,
              helperMaxLines: 2,
            ),
          ),
        ),

        const SizedBox(height: 8),

        // Auto-start toggle
        SwitchListTile(
          title: Text(l10n.portForwardAutoActivate),
          subtitle: Text(l10n.portForwardAutoActivateDesc),
          value: autoStart,
          onChanged: onAutoStartChanged,
          contentPadding: EdgeInsets.zero,
        ),
        ],
      ],
    );
  }

  /// A phone's and a tablet's fields: each in the app's own field, its name
  /// in the cell beside its value (above it where the two do not fit), and
  /// Auto-activate with the app's switch. They were Material's outlined
  /// boxes with floating names, the one form of the kind left on a phone
  /// (a design audit).
  Widget _touchFields(BuildContext context, AppLocalizations l10n) {
    final portName = _isDynamic ? l10n.portForwardSocksPort : l10n.portForwardSourcePort;
    String? port(String? v) {
      if (v == null || v.isEmpty) return l10n.required;
      final n = int.tryParse(v);
      if (n == null || n < 1 || n > 65535) return l10n.portForwardPortInvalid;
      return null;
    }

    Widget field(String name, Widget value, {String? helper, Key? key}) =>
        ZestField.custom(key: key, label: name, helperText: helper, child: value);

    return ZestFieldLabels(
      labels: [
        l10n.portForwardNicknameOptional,
        portName,
        if (!_isDynamic) ...[l10n.portForwardDestinationHost, l10n.portForwardDestinationPort],
        l10n.portForwardBindAddress,
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          field(
            l10n.portForwardNicknameOptional,
            key: const ValueKey('pf-touch-name'),
            TextFormField(
              controller: labelController,
              style: _touchValue,
              decoration: _touchDecoration(l10n.portForwardNicknameHint),
              textCapitalization: TextCapitalization.words,
            ),
          ),
          const SizedBox(height: 8),
          field(
            portName,
            key: const ValueKey('pf-touch-port'),
            TextFormField(
              controller: bindPortController,
              style: _touchMono,
              decoration: _touchDecoration(_isDynamic ? '1080' : '8080'),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              validator: port,
            ),
          ),
          // The remote host and the bind address are identifiers: while
          // recording they are drawn masked and read-only (the required
          // check still runs on the real value).
          if (!_isDynamic) ...[
            const SizedBox(height: 8),
            field(
              l10n.portForwardDestinationHost,
              key: const ValueKey('pf-touch-destination-host'),
              RecordingMaskedFormField(
                controller: remoteHostController,
                mask: (v) => Redactable.address(v).display,
                style: _touchMono,
                decoration: _touchDecoration(l10n.portForwardRemoteHostHint),
                validate: () => remoteHostController.text.isEmpty ? l10n.required : null,
                child: TextFormField(
                  controller: remoteHostController,
                  style: _touchMono,
                  decoration: _touchDecoration(l10n.portForwardRemoteHostHint),
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  validator: (v) => v == null || v.isEmpty ? l10n.required : null,
                ),
              ),
            ),
            const SizedBox(height: 8),
            field(
              l10n.portForwardDestinationPort,
              key: const ValueKey('pf-touch-destination-port'),
              TextFormField(
                controller: remotePortController,
                style: _touchMono,
                decoration: _touchDecoration(l10n.portForwardRemotePortHint),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                validator: port,
              ),
            ),
          ],
          const SizedBox(height: 8),
          field(
            l10n.portForwardBindAddress,
            key: const ValueKey('pf-touch-bind-address'),
            helper: l10n.portForwardBindAddressHelper,
            RecordingMaskedFormField(
              controller: bindAddressController,
              mask: (v) => Redactable.address(v).display,
              style: _touchMono,
              decoration: _touchDecoration('127.0.0.1'),
              child: TextFormField(
                controller: bindAddressController,
                style: _touchMono,
                decoration: _touchDecoration('127.0.0.1'),
                keyboardType: TextInputType.url,
                autocorrect: false,
              ),
            ),
          ),
          const SizedBox(height: 18),
          _TouchSwitchRow(
            key: const ValueKey('pf-touch-auto-start'),
            title: l10n.portForwardAutoActivate,
            line: l10n.portForwardAutoActivateDesc,
            value: autoStart,
            onChanged: onAutoStartChanged,
          ),
        ],
      ),
    );
  }
}

/// A value in a phone's port forward field, as the app's fields draw one
/// ([ZestField]); an address or a port in monospace.
TextStyle get _touchValue => TextStyle(fontSize: 13, height: 1.25, color: ZestTokens.textPrimary);
TextStyle get _touchMono => _touchValue.copyWith(fontFamily: 'JetBrainsMono', letterSpacing: 0.4);

/// The bare look of a value inside the app's field, its hint in the muted
/// text, which reads on the field in every theme (as the host editor's).
InputDecoration _touchDecoration(String hint) => zestShellFieldDecoration(hintText: hint)
    .copyWith(hintStyle: TextStyle(color: ZestTokens.textTertiary, fontSize: 13));

/// A switch with its name and, under it, what it does: the row a computer's
/// port forwarding has, with the app's own switch; the whole row toggles.
class _TouchSwitchRow extends StatelessWidget {
  const _TouchSwitchRow({super.key, required this.title, required this.line, required this.value, required this.onChanged});

  final String title;
  final String line;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onChanged(!value),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 14, color: ZestTokens.textPrimary)),
                const SizedBox(height: 3),
                Text(line, style: TextStyle(fontSize: 12.5, height: 1.35, color: ZestTokens.textTertiary)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          ZestSwitch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

// ── Shared state mixin ──────────────────────────────────────────

/// Common state + helpers shared by the mobile page and desktop dialog.
mixin _PortForwardFormMixin<T extends StatefulWidget> on State<T> {
  PortForwardType type = PortForwardType.local;
  final labelController = TextEditingController();
  final bindAddressController = TextEditingController(text: '127.0.0.1');
  final bindPortController = TextEditingController();
  final remoteHostController = TextEditingController(text: 'localhost');
  final remotePortController = TextEditingController();
  final formKey = GlobalKey<FormState>();
  bool autoStart = true;

  PortForwardResult? get initial;

  void initForm() {
    if (initial != null) {
      final fwd = initial!;
      type = _typeFromString(fwd.type);
      labelController.text = fwd.label ?? '';
      bindAddressController.text = fwd.bindAddress;
      bindPortController.text = fwd.bindPort.toString();
      remoteHostController.text = fwd.remoteHost;
      remotePortController.text =
          fwd.remotePort > 0 ? fwd.remotePort.toString() : '';
      autoStart = fwd.autoStart;
    }
  }

  static PortForwardType _typeFromString(String t) {
    switch (t) {
      case 'remote':
        return PortForwardType.remote;
      case 'dynamic':
        return PortForwardType.dynamic;
      default:
        return PortForwardType.local;
    }
  }

  static String _typeToString(PortForwardType t) {
    switch (t) {
      case PortForwardType.remote:
        return 'remote';
      case PortForwardType.dynamic:
        return 'dynamic';
      case PortForwardType.local:
        return 'local';
    }
  }

  void disposeControllers() {
    labelController.dispose();
    bindAddressController.dispose();
    bindPortController.dispose();
    remoteHostController.dispose();
    remotePortController.dispose();
  }

  void applyPreset(String name) {
    setState(() {
      switch (name) {
        case 'web':
          type = PortForwardType.local;
          labelController.text =
              AppLocalizations.of(context)!.portForwardPresetWebService;
          bindPortController.text = '8080';
          remoteHostController.text = 'localhost';
          remotePortController.text = '80';
        case 'database':
          type = PortForwardType.local;
          labelController.text =
              AppLocalizations.of(context)!.portForwardPresetDatabase;
          bindPortController.text = '5432';
          remoteHostController.text = 'localhost';
          remotePortController.text = '5432';
        case 'socks':
          type = PortForwardType.dynamic;
          labelController.text =
              AppLocalizations.of(context)!.portForwardPresetSocksProxy;
          bindPortController.text = '1080';
      }
    });
  }

  PortForwardResult? submitForm() {
    if (!formKey.currentState!.validate()) return null;
    final isDynamic = type == PortForwardType.dynamic;
    final label = labelController.text.trim();
    return PortForwardResult(
      id: initial?.id ?? const Uuid().v4(),
      type: _typeToString(type),
      bindAddress: bindAddressController.text.trim().isEmpty
          ? '127.0.0.1'
          : bindAddressController.text.trim(),
      bindPort: int.parse(bindPortController.text),
      remoteHost: isDynamic ? '*' : remoteHostController.text.trim(),
      remotePort: isDynamic ? 0 : int.parse(remotePortController.text),
      label: label.isEmpty ? null : label,
      autoStart: autoStart,
    );
  }
}

// ── Mobile: full-screen page ────────────────────────────────────

class _AddForwardPage extends StatefulWidget {
  final PortForwardResult? initial;

  /// The rule's Delete (see [showPortForwardEditor]); none for a new one.
  final Future<bool> Function()? onDelete;

  /// The saved rule's Move or copy in the app bar (see [showPortForwardEditor]).
  final bool movable;
  const _AddForwardPage({this.initial, this.onDelete, this.movable = false});

  @override
  State<_AddForwardPage> createState() => _AddForwardPageState();
}

class _AddForwardPageState extends State<_AddForwardPage>
    with _PortForwardFormMixin {
  @override
  PortForwardResult? get initial => widget.initial;

  @override
  void initState() {
    super.initState();
    initForm();
  }

  @override
  void dispose() {
    disposeControllers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isEditing = widget.initial != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          isEditing ? l10n.portForwardEditTitle : l10n.portForwardNewTitle,
        ),
        leading: IconButton(
          tooltip: AppLocalizations.of(context)!.close,
          icon: const Icon(LucideIcons.x),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          if (widget.movable)
            MoveCopyMenuButton(
              kind: TransferKinds.forward,
              itemKey: widget.initial!.id,
              onMoved: () {
                if (mounted) Navigator.pop(context);
              },
            ),
          IconButton(
            icon: Icon(LucideIcons.helpCircle, color: AppColors.accentInk),
            tooltip: l10n.portForwardHelpTitle,
            onPressed: () => _showPortForwardHelp(context),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: () {
                final result = submitForm();
                if (result != null) Navigator.pop(context, result);
              },
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.orange,
                foregroundColor: AppColors.onBrand(AppColors.orange),
              ),
              child: Text(isEditing ? l10n.save : l10n.portForwardAdd),
            ),
          ),
        ],
      ),
      // On a tablet, the one centred column a phone page takes there (the
      // form ran the full width, 1000 pixels and more).
      body: Form(
        key: formKey,
        child: PhonePageColumn(
          key: const ValueKey('pf-touch-column'),
          child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          children: [
            _PortForwardFormBody(
              initial: widget.initial,
              type: type,
              onTypeChanged: (t) => setState(() => type = t),
              labelController: labelController,
              bindAddressController: bindAddressController,
              bindPortController: bindPortController,
              remoteHostController: remoteHostController,
              remotePortController: remotePortController,
              autoStart: autoStart,
              onAutoStartChanged: (v) => setState(() => autoStart = v),
              onPreset: (name) => () => applyPreset(name),
              touch: true,
            ),
            // Delete is here, on the rule's own page, not on its row in the
            // list (3.0); it asks first.
            if (widget.onDelete != null) ...[
              const SizedBox(height: 28),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  key: const ValueKey('forward-delete'),
                  onPressed: () async {
                    final deleted = await widget.onDelete!();
                    if (deleted && context.mounted) Navigator.pop(context);
                  },
                  style: TextButton.styleFrom(foregroundColor: AppColors.error),
                  icon: const Icon(LucideIcons.trash2, size: 18),
                  label: Text(l10n.homeDeletePortForward),
                ),
              ),
            ],
          ],
        ),
        ),
      ),
    );
  }
}

// ── Help bottom sheet ──────────────────────────────────────────

void _showPortForwardHelp(BuildContext context) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF1A1A1A),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => const _PortForwardHelpSheet(),
  );
}

class _PortForwardHelpSheet extends StatelessWidget {
  const _PortForwardHelpSheet();

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        final l10n = AppLocalizations.of(context)!;
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: ListView(
            controller: scrollController,
            children: [
              // Title
              Text(
                l10n.portForwardHelpTitle,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: AppColors.accentInk,
                ),
              ),
              const SizedBox(height: 20),
              ...sections(l10n),
            ],
          ),
        );
      },
    );
  }

  /// What the help says, under its title: on a phone's sheet, and in place
  /// of the form in a computer's dialog (which opened it over itself).
  static List<Widget> sections(AppLocalizations l10n) => [
              // What is this?
              _helpSectionHeader(l10n.portForwardHelpWhatHeader),
              const SizedBox(height: 6),
              Text(
                l10n.portForwardHelpWhatBody,
                style: TextStyle(fontSize: 14, color: AppColors.onSurface, height: 1.5),
              ),
              const SizedBox(height: 20),

              // Which type?
              _helpSectionHeader(l10n.portForwardHelpWhichHeader),
              const SizedBox(height: 6),
              _helpBullet(
                l10n.portForwardHelpLocalLabel,
                l10n.portForwardHelpLocalDesc,
              ),
              _helpBullet(
                l10n.portForwardHelpRemoteLabel,
                l10n.portForwardHelpRemoteDesc,
              ),
              _helpBullet(
                l10n.portForwardHelpSocksLabel,
                l10n.portForwardHelpSocksDesc,
              ),
              const SizedBox(height: 20),

              // Field explanations
              _helpSectionHeader(l10n.portForwardHelpFieldsHeader),
              const SizedBox(height: 6),
              _helpField(l10n.portForwardHelpFieldNickname,
                  l10n.portForwardHelpFieldNicknameDesc),
              _helpField(
                l10n.portForwardHelpFieldSourcePort,
                l10n.portForwardHelpFieldSourcePortDesc,
              ),
              _helpField(
                l10n.portForwardHelpFieldDestHost,
                l10n.portForwardHelpFieldDestHostDesc,
              ),
              _helpField(
                l10n.portForwardHelpFieldDestPort,
                l10n.portForwardHelpFieldDestPortDesc,
              ),
              _helpField(
                l10n.portForwardHelpFieldBindAddress,
                l10n.portForwardHelpFieldBindAddressDesc,
              ),
              _helpField(
                l10n.portForwardHelpFieldAutoActivate,
                l10n.portForwardHelpFieldAutoActivateDesc,
              ),
              const SizedBox(height: 20),

              // Quick example
              _helpSectionHeader(l10n.portForwardHelpExampleHeader),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.surfaceLight,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: AppColors.divider,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.portForwardHelpExampleTitle,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.onSurface,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${l10n.portForwardSourcePort}: 8080\n'
                      '${l10n.portForwardDestinationHost}: 192.168.1.10\n'
                      '${l10n.portForwardDestinationPort}: 8006',
                      style: TextStyle(
                        fontSize: 13,
                        fontFamily: 'JetBrainsMono',
                        color: AppColors.onSurface,
                        height: 1.6,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l10n.portForwardHelpExampleOpen('http://localhost:8080'),
                      style: TextStyle(
                        fontSize: 13,
                        fontFamily: 'JetBrainsMono',
                        color: AppColors.accentInk,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // Common mistakes
              _helpSectionHeader(l10n.portForwardHelpMistakesHeader),
              const SizedBox(height: 6),
              _helpMistake(l10n.portForwardHelpMistakePortsSwapped),
              _helpMistake(l10n.portForwardHelpMistakePort22),
              _helpMistake(l10n.portForwardHelpMistakeSessionClosed),
              _helpMistake(l10n.portForwardHelpMistakeLocalhost),
              const SizedBox(height: 16),
            ];

  static Widget _helpSectionHeader(String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.bold,
        color: AppColors.accentInk,
      ),
    );
  }

  static Widget _helpBullet(String label, String description) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('\u2022 ', style: TextStyle(color: AppColors.accentInk, fontSize: 14)),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '$label: ',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      color: AppColors.onSurface,
                    ),
                  ),
                  TextSpan(
                    text: description,
                    style: TextStyle(
                      fontSize: 14,
                      color: AppColors.onSurface,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static Widget _helpField(String fieldName, String description) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('\u2022 ', style: TextStyle(color: AppColors.accentInk, fontSize: 14)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  fieldName,
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: AppColors.accentInk,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 14,
                    color: AppColors.onSurface,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static Widget _helpMistake(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '\u2716 ',
            style: TextStyle(color: AppColors.error, fontSize: 13),
          ),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 14,
                color: AppColors.onSurface,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Desktop: dialog ─────────────────────────────────────────────

class _AddForwardDialog extends StatefulWidget {
  final PortForwardResult? initial;
  const _AddForwardDialog({super.key, this.initial});

  @override
  State<_AddForwardDialog> createState() => _AddForwardDialogState();
}

class _AddForwardDialogState extends State<_AddForwardDialog>
    with _PortForwardFormMixin {
  @override
  PortForwardResult? get initial => widget.initial;

  @override
  void initState() {
    super.initState();
    initForm();
  }

  @override
  void dispose() {
    disposeControllers();
    super.dispose();
  }

  /// The help shows in place of the form (the dialog rules of 3.4: it was a
  /// sheet opened over the dialog); the form keeps what was typed.
  bool _help = false;

  /// Adds (or saves) it, from the main button or Enter.
  void submit() {
    if (_help) return;
    final result = submitForm();
    if (result != null) Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isEditing = widget.initial != null;
    if (_help) {
      return ZestDialogShell(
        size: ZestModalSize.standard,
        tone: ZestDialogTone.info,
        icon: LucideIcons.helpCircle,
        title: l10n.portForwardHelpTitle,
        body: Column(
          key: const ValueKey('pf-help-in-place'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: _PortForwardHelpSheet.sections(l10n),
        ),
        primaryKey: const ValueKey('pf-help-back'),
        primaryAction: (label: l10n.back, icon: null, onPressed: () => setState(() => _help = false)),
        autofocusPrimary: true,
      );
    }
    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.arrowLeftRight,
      title: isEditing ? l10n.portForwardEditTitle : l10n.portForwardNewTitle,
      body: Form(
        key: formKey,
        child: _PortForwardFormBody(
          initial: widget.initial,
          type: type,
          onTypeChanged: (t) => setState(() => type = t),
          labelController: labelController,
          bindAddressController: bindAddressController,
          bindPortController: bindPortController,
          remoteHostController: remoteHostController,
          remotePortController: remotePortController,
          autoStart: autoStart,
          onAutoStartChanged: (v) => setState(() => autoStart = v),
          onPreset: (name) => () => applyPreset(name),
        ),
      ),
      // The help, a link at the left of the footer, in this dialog's place.
      tertiaryKey: const ValueKey('pf-help'),
      tertiaryAction: (label: l10n.portForwardHelpTitle, onPressed: () => setState(() => _help = true)),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.pop(context)),
      primaryAction: (label: isEditing ? l10n.save : l10n.portForwardAdd, icon: null, onPressed: submit),
    );
  }

}
