import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/features/orchards/move/item_transfer.dart' show TransferKinds;
import 'package:zestssh/features/orchards/move/move_copy_menu.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/desktop/widgets/port_forward_edit_controller.dart';
import 'package:zestssh/ui/widgets/connection_picker_dialog.dart';
import 'package:zestssh/ui/widgets/recording_masked_field.dart';
import 'package:zestssh/ui/widgets/recording_reveal_gate.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/tunnel_diagram.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_detail_scaffold.dart';
import 'package:zestssh/ui/widgets/zest_field.dart';
import 'package:zestssh/ui/widgets/zest_mode_toggle.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/ui/widgets/host_row.dart';
import 'package:zestssh/ui/widgets/zest_pressable.dart';

/// Below this inner width the tunnel diagram goes under the fields, full
/// width, instead of beside them: beside them each of its three nodes was
/// too narrow for an endpoint such as `localhost:65535`, which broke inside
/// the word.
const double _kPfDiagramBesideWidth = 900;

/// The left label-cell width for THIS pane. Port Forwarding has the app's
/// longest field labels ("Service port"), so it overrides [ZestField]'s 88px
/// default with a wider PF-specific cell. Every field in a column - [ZestField],
/// [ZestFieldGroup] and the custom [_CombinedFieldRow] rows here - is given this
/// same width, so no label clips and all label cells align on one vertical rule.
const double _kPfLabelWidth = 120;

/// The fixed width of a combined-field port cell (§4.4 - matches the mockup).
const double _kPfPortWidth = 74;

/// The right-hand detail pane of the 1.7 Port Forwarding master/detail. Composes
/// the [ZestDetailScaffold] (sticky footer, dirty dot, close X) + the
/// Simple/Advanced [ZestModeToggle] + the active editor.
///
/// The detail pane ALWAYS renders the editor - a blank/creating controller is a
/// ready-to-fill "new rule" form, so there is no empty state. The footer Clear
/// (`onCancel`) resets to a blank new rule.
class PortForwardDetailPane extends ConsumerWidget {
  const PortForwardDetailPane({
    super.key,
    required this.controller,
    required this.hasSelection,
    required this.onSave,
    this.onSaveAndStart,
    required this.onClose,
    required this.onDelete,
    required this.onModeChanged,
    this.saveIn,
    this.onMoved,
  });

  /// After a saved rule's Move or copy (4.0, in the header) moved it: it is
  /// not here any more.
  final VoidCallback? onMoved;

  final PortForwardEditController controller;

  /// "Save in" (3.4), over a new rule's fields.
  final Widget? saveIn;
  final bool hasSelection;
  final Future<bool> Function() onSave;

  /// Saves the rule and starts it (the footer's Save and start); none where
  /// the pane offers only Save.
  final Future<void> Function()? onSaveAndStart;
  final VoidCallback onClose;
  final VoidCallback onDelete;
  final ValueChanged<PfEditorMode> onModeChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => _editor(context, ref),
    );
  }

  Widget _editor(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final showDelete = !controller.isCreating;

    return ZestDetailScaffold(
      title: _title(l10n, ref),
      icon: LucideIcons.arrowLeftRight,
      // (A new rule's header is its title alone, as the mockup draws it.)
      subtitle: controller.isCreating ? null : _tunnelSubtitle(ref),
      subtitleMono: true,
      modeToggle: _modeToggle(l10n),
      isDirty: controller.isDirty,
      onSave: () => onSave(),
      onClose: onClose,
      // A saved rule's Move or copy (4.0): its places, then Move here or
      // Copy here.
      headerAction: switch (controller.original) {
        final rule? when !controller.isCreating => MoveCopyMenuButton(
            kind: TransferKinds.forward,
            itemKey: rule.id,
            iconSize: 18,
            color: ZestTokens.textSecondary,
            hasUnsavedChanges: () => controller.isDirty,
            onMoved: onMoved,
          ),
        _ => null,
      },
      footer: _PfFooter(
        onSave: () => onSave(),
        saveEnabled: controller.isDirty,
        onSaveAndStart: onSaveAndStart == null ? null : () => onSaveAndStart!(),
        onDelete: showDelete ? onDelete : null,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (controller.isCreating && saveIn != null)
            Padding(padding: const EdgeInsets.fromLTRB(20, 4, 20, 8), child: saveIn!),
          if (controller.mode == PfEditorMode.simple)
            _SimpleBody(controller: controller)
          else
            _AdvancedBody(controller: controller),
        ],
      ),
    );
  }

  /// The header title in its display form (recording mode): a nickname may
  /// embed a host, the fallback IS the remote address.
  String _title(AppLocalizations l10n, WidgetRef ref) {
    final rule = controller.original;
    if (rule == null) return l10n.zestPfNewLabel;
    if (rule.label != null && rule.label!.isNotEmpty) {
      return Redactable.freeText(rule.label!).displayIn(ref);
    }
    switch (rule.type) {
      case 'dynamic':
        return 'SOCKS5 :${rule.bindPort}';
      default:
        return Redactable.address('${rule.remoteHost}:${rule.remotePort}')
            .displayIn(ref);
    }
  }

  /// The mono subtitle: a compact tunnel summary built live from the fields,
  /// e.g. `db-primary · 5432 → localhost:5432` (real U+2192 arrow). Returns
  /// null for a still-empty new rule so no subtitle line shows.
  String? _tunnelSubtitle(WidgetRef ref) {
    final simple = controller.mode == PfEditorMode.simple;
    final type = simple ? controller.forwardType : controller.advancedType;
    final name = controller.nameController.text.trim();
    // Display forms (recording mode): the nickname may embed a host, the
    // destination host is an address.
    final shownName =
        name.isEmpty ? '' : Redactable.freeText(name).displayIn(ref);
    final prefix = name.isEmpty ? '' : '$shownName · ';
    const arrow = ' → ';

    switch (type) {
      case PfForwardType.dynamic:
        final port = simple
            ? controller.simpleBindPortController.text.trim()
            : controller.advSourcePortController.text.trim();
        if (port.isEmpty) return name.isEmpty ? null : shownName;
        return '${prefix}SOCKS5 :$port';
      case PfForwardType.local:
      case PfForwardType.remote:
        final String srcPort;
        final String destHost;
        final String destPort;
        if (simple) {
          // Simple mode maps My/Service/Server ports onto bind/remote per type;
          // present the tunnel in its natural source -> destination direction.
          if (type == PfForwardType.local) {
            srcPort = controller.simpleBindPortController.text.trim();
            destPort = controller.simpleRemotePortController.text.trim();
          } else {
            srcPort = controller.simpleRemotePortController.text.trim();
            destPort = controller.simpleBindPortController.text.trim();
          }
          destHost = 'localhost';
        } else {
          srcPort = controller.advSourcePortController.text.trim();
          final h = controller.advDestHostController.text.trim();
          destHost =
              h.isEmpty ? 'localhost' : Redactable.address(h).displayIn(ref);
          destPort = controller.advDestPortController.text.trim();
        }
        if (srcPort.isEmpty && destPort.isEmpty) {
          return name.isEmpty ? null : shownName;
        }
        return '$prefix$srcPort$arrow$destHost:$destPort';
    }
  }

  Widget _modeToggle(AppLocalizations l10n) {
    return ZestModeToggle(
      selectedId: controller.mode.name,
      onChanged: (id) => onModeChanged(
        id == PfEditorMode.advanced.name
            ? PfEditorMode.advanced
            : PfEditorMode.simple,
      ),
      segments: [
        ZestModeSegment(id: PfEditorMode.simple.name, label: l10n.zestModeSimple),
        ZestModeSegment(
            id: PfEditorMode.advanced.name, label: l10n.zestModeAdvanced),
      ],
    );
  }
}

/// Resolve the scoped connection (host, identity) for the current rule.
ConnectionWithDetails? _scopedConnection(WidgetRef ref, String? id) {
  if (id == null) return null;
  final list =
      ref.watch(connectionsWithDetailsProvider).valueOrNull ?? const [];
  for (final c in list) {
    if (c.connection.id == id) return c;
  }
  return null;
}

/// Open the shared grouped connection picker and scope the rule to the choice.
Future<void> _pickConnection(
    BuildContext context, PortForwardEditController controller) async {
  final l10n = AppLocalizations.of(context)!;
  final result = await ConnectionPickerDialog.show(
    context,
    title: l10n.zestPfChooseConnection,
    needsTerminal: true,
  );
  final picked = result.connection;
  if (picked != null) controller.setConnectionId(picked.connection.id);
}

// The REAL host / username feed only the copied `ssh` command (behind the
// reveal gate); everything painted - the preview, the diagram, the picker
// value - takes the display forms below (recording mode).
String _hostOf(ConnectionWithDetails? c) => c?.connection.host ?? '';
String? _userOf(ConnectionWithDetails? c) => c?.identity?.username;
String _hostShown(WidgetRef ref, ConnectionWithDetails? c) =>
    c == null ? '' : Redactable.address(c.connection.host).displayIn(ref);
String? _userShown(WidgetRef ref, ConnectionWithDetails? c) {
  final user = c?.identity?.username;
  return user == null ? null : Redactable.username(user).displayIn(ref);
}

String _serverNameOf(
        WidgetRef ref, ConnectionWithDetails? c, String fallback) =>
    (c?.connection.label.isNotEmpty ?? false)
        ? Redactable.host(c!.connection.label).displayIn(ref)
        : fallback;
String? _pickerValue(WidgetRef ref, ConnectionWithDetails? c) => c == null
    ? null
    : '${Redactable.host(c.connection.label).displayIn(ref)} · '
        '${_hostShown(ref, c)}';

// ══════════════════════════════════════════════════════════════════
// Simple mode: what to do, the
// fields, the two ends with what happens, the two switches, the command
// ══════════════════════════════════════════════════════════════════

class _SimpleBody extends ConsumerWidget {
  const _SimpleBody({required this.controller});

  final PortForwardEditController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final scoped = _scopedConnection(ref, controller.connectionId);
    final type = controller.forwardType;
    final serverName = _serverNameOf(ref, scoped, l10n.zestPfNodeServerFallback);
    final here = int.tryParse(controller.simpleBindPortController.text.trim());
    final there = int.tryParse(controller.simpleRemotePortController.text.trim());
    final labelWidth = zestFieldLabelWidth(
        context, [l10n.zestPfNameLabel, l10n.zestPfServerLabel, l10n.pfPagePortHere, l10n.pfPagePortOnServer],
        min: 120);
    final (herePlaceholder, therePlaceholder) = switch (type) {
      PfForwardType.local => ('8080', '80'),
      PfForwardType.remote => ('3000', '8080'),
      PfForwardType.dynamic => ('1080', ''),
    };

    String? othersLine() {
      if (type == PfForwardType.remote) {
        if (there == null) return null;
        return controller.gatewayPorts
            ? l10n.pfPageOthersOnServer(serverName, there)
            : l10n.pfPageOthersOffServer(serverName, there);
      }
      if (here == null) return null;
      return controller.gatewayPorts ? l10n.pfPageOthersOnHere(here) : l10n.pfPageOthersOffHere(here);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _FieldLabel(label: l10n.zestPfQuestion),
          const SizedBox(height: 10),
          for (final (t, title, desc, tag) in [
            (PfForwardType.local, l10n.pfPageLocalTitle, l10n.pfPageLocalDesc, l10n.zestPfBadgeLocal),
            (PfForwardType.remote, l10n.pfPageRemoteTitle, l10n.pfPageRemoteDesc, l10n.zestPfBadgeRemote),
            (PfForwardType.dynamic, l10n.pfPageDynamicTitle, l10n.pfPageDynamicDesc, l10n.zestPfBadgeDynamic),
          ]) ...[
            _RadioCard(
              key: ValueKey('pf-intent-${t.name}'),
              title: title,
              description: desc,
              tag: tag,
              isSelected: type == t,
              onTap: () => controller.setForwardType(t),
            ),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 10),
          ZestField(
            key: const ValueKey('pf-name'),
            label: l10n.zestPfNameLabel,
            controller: controller.nameController,
            placeholder: l10n.zestPfNameHint,
            labelWidth: labelWidth,
            onChanged: (_) => controller.markDirty(),
          ),
          const SizedBox(height: 7),
          _PickerFieldRow(
            label: l10n.zestPfServerLabel,
            valueText: scoped == null ? null : _serverNameOf(ref, scoped, _hostShown(ref, scoped)),
            leading: scoped == null ? null : _HostGlyph(host: scoped),
            hint: l10n.zestPfChooseConnection,
            labelWidth: labelWidth,
            onTap: () => _pickConnection(context, controller),
          ),
          const SizedBox(height: 7),
          _portField(context, l10n.pfPagePortHere, controller.simpleBindPortController, herePlaceholder, labelWidth,
              const ValueKey('pf-port-here')),
          if (type != PfForwardType.dynamic) ...[
            const SizedBox(height: 7),
            _portField(context, l10n.pfPagePortOnServer, controller.simpleRemotePortController, therePlaceholder,
                labelWidth, const ValueKey('pf-port-server')),
          ],
          const SizedBox(height: 16),
          _TunnelCard(type: type, here: here, there: there, serverName: serverName),
          const SizedBox(height: 18),
          _SwitchLine(
            key: const ValueKey('pf-auto-start'),
            title: l10n.zestPfOptAutoStart,
            value: controller.autoStart,
            onChanged: controller.setAutoStart,
          ),
          const SizedBox(height: 14),
          _SwitchLine(
            key: const ValueKey('pf-let-others'),
            title: l10n.pfPageLetOthers,
            line: othersLine(),
            value: controller.gatewayPorts,
            onChanged: controller.setGatewayPorts,
          ),
          const SizedBox(height: 20),
          Text(
            l10n.pfPageOpenSsh,
            style: TextStyle(fontSize: 12, color: ZestTokens.textTertiary),
          ),
          const SizedBox(height: 8),
          _commandPreview(ref, scoped),
        ],
      ),
    );
  }

  Widget _portField(BuildContext context, String label, TextEditingController ctrl, String placeholder,
      double labelWidth, Key key) {
    return ZestField(
      key: key,
      label: label,
      controller: ctrl,
      placeholder: placeholder,
      isMono: true,
      labelWidth: labelWidth,
      errorText: _portError(context, ctrl.text),
      onChanged: (_) => controller.markDirty(),
    );
  }

  Widget _commandPreview(WidgetRef ref, ConnectionWithDetails? scoped) {
    // Painted segments take the display forms; the copied command stays real
    // (the copy button runs the reveal gate while recording).
    final shown = controller.simplePreviewSegments(
      host: _hostShown(ref, scoped),
      username: _userShown(ref, scoped),
    );
    final real = controller.simplePreviewSegments(
      host: _hostOf(scoped),
      username: _userOf(scoped),
    );
    return _CommandPreview(
      segments: shown,
      command: real.map((s) => s.text).join(),
    );
  }
}

/// The two ends of a forward with the ssh tunnel between them, the side
/// where connections come in on the left, and what happens while it runs.
class _TunnelCard extends StatelessWidget {
  const _TunnelCard({required this.type, required this.here, required this.there, required this.serverName});

  final PfForwardType type;
  final int? here;
  final int? there;
  final String serverName;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    String at(int? port) => port == null ? 'localhost:<port>' : 'localhost:$port';
    final device = _End(icon: LucideIcons.laptop, title: l10n.zestPfNodeThisDevice, address: at(here), missing: here == null);
    final server = _End(icon: LucideIcons.server, title: serverName, address: at(there), missing: there == null);
    final (left, right) = switch (type) {
      PfForwardType.local => (device, server),
      PfForwardType.remote => (server, device),
      PfForwardType.dynamic => (
          device,
          _End(icon: LucideIcons.globe, title: l10n.pfPageInternet, address: serverName),
        ),
    };
    final sentence = switch (type) {
      PfForwardType.local when here != null && there != null => l10n.pfPageSentenceLocal(here!, there!, serverName),
      PfForwardType.remote when here != null && there != null => l10n.pfPageSentenceRemote(serverName, there!, here!),
      PfForwardType.dynamic when here != null => l10n.pfPageSentenceDynamic(here!, serverName),
      _ => l10n.pfPageSentenceIncomplete,
    };
    return Container(
      key: const ValueKey('pf-tunnel-card'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceRaisedAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ZestTokens.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: left),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(LucideIcons.moveRight, size: 20, color: ZestTokens.textTertiary),
                      const SizedBox(height: 2),
                      Text(
                        l10n.pfPageTunnel,
                        style: TextStyle(fontSize: 10.5, fontFamily: 'JetBrainsMono', color: ZestTokens.textTertiary),
                      ),
                    ],
                  ),
                ),
                Expanded(child: right),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            sentence,
            key: const ValueKey('pf-tunnel-sentence'),
            style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// One end of the tunnel: what it is, and the address there.
class _End extends StatelessWidget {
  const _End({required this.icon, required this.title, required this.address, this.missing = false});

  final IconData icon;
  final String title;
  final String address;
  final bool missing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceRaised,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ZestTokens.borderSubtle),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 16, color: ZestTokens.textSecondary),
          const SizedBox(height: 6),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: ZestTokens.textPrimary),
          ),
          const SizedBox(height: 3),
          Text(
            address,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              fontFamily: 'JetBrainsMono',
              // Still to be filled: quiet, but at 4.5:1 (the turned-off grey
              // was under 3:1); its words ("<port>") say it is missing.
              color: missing ? ZestTokens.textTertiary : ZestTokens.brandInk,
            ),
          ),
        ],
      ),
    );
  }
}

/// A switch with its name and, under it, what it does now.
class _SwitchLine extends StatelessWidget {
  const _SwitchLine({super.key, required this.title, required this.value, required this.onChanged, this.line});

  final String title;
  final String? line;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    // One thing to a screen reader: its name, what it does now, and the
    // switch's state (the switch was an unnamed toggle beside its words).
    return MergeSemantics(
      child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onChanged(!value),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 13.5, color: ZestTokens.textPrimary)),
                if (line != null) ...[
                  const SizedBox(height: 3),
                  Text(line!, style: TextStyle(fontSize: 12, height: 1.35, color: ZestTokens.textTertiary)),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          ZestSwitch(value: value, onChanged: onChanged),
        ],
      ),
      ),
    );
  }
}

/// A host's own icon, as its card draws it.
class _HostGlyph extends ConsumerWidget {
  const _HostGlyph({required this.host});

  final ConnectionWithDetails host;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return HostGlyph(host: host.connection, group: host.group, size: 18, cornerRadius: 5);
  }
}

/// The editor's footer: Delete for a saved rule; Save, and Save and start
/// (the header's close leaves the editor).
class _PfFooter extends StatelessWidget {
  const _PfFooter({
    required this.onSave,
    required this.saveEnabled,
    this.onSaveAndStart,
    this.onDelete,
  });

  final VoidCallback onSave;
  final bool saveEnabled;
  final VoidCallback? onSaveAndStart;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ZestTokens.surfacePanel,
        border: Border(top: BorderSide(color: ZestTokens.borderSubtle, width: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          children: [
            // Delete as its icon alone: four labelled buttons did not fit
            // the pane in every language.
            if (onDelete != null)
              IconButton(
                key: const ValueKey('pf-delete'),
                icon: const Icon(LucideIcons.trash2, size: 17),
                color: ZestTokens.statusCritical,
                tooltip: MaterialLocalizations.of(context).deleteButtonTooltip,
                onPressed: onDelete,
              ),
            const SizedBox(width: 8),
            // The two go to a second line where the pane is too narrow for
            // them in one (a long language, a small window).
            Expanded(
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: ZestSizing.buttonGap,
                runSpacing: 8,
                children: [
                  ZestButton(
                    key: const ValueKey('pf-save'),
                    label: l10n.zestCommonSave,
                    variant: ZestButtonVariant.secondary,
                    size: ZestButtonSize.large,
                    onPressed: saveEnabled ? onSave : null,
                  ),
                  if (onSaveAndStart != null)
                    ZestButton(
                      key: const ValueKey('pf-save-start'),
                      label: l10n.pfPageSaveAndStart,
                      variant: ZestButtonVariant.primary,
                      size: ZestButtonSize.large,
                      onPressed: onSaveAndStart,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Advanced mode - two-column raw form (left) + diagram/options (right)
// ══════════════════════════════════════════════════════════════════

class _AdvancedBody extends ConsumerWidget {
  const _AdvancedBody({required this.controller});

  final PortForwardEditController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scoped = _scopedConnection(ref, controller.connectionId);
    return LayoutBuilder(
      builder: (context, constraints) {
        // Inside the 24 of padding on each side.
        final wide = constraints.maxWidth - 48 >= _kPfDiagramBesideWidth;
        final left = _leftColumn(context, ref, scoped);
        final right = _rightColumn(context, ref, scoped);
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (wide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 13, child: left),
                    const SizedBox(width: 18),
                    Expanded(flex: 10, child: right),
                  ],
                )
              else ...[
                left,
                const SizedBox(height: 18),
                right,
              ],
              const SizedBox(height: 18),
              _commandPreview(context, ref, scoped),
            ],
          ),
        );
      },
    );
  }

  Widget _leftColumn(
      BuildContext context, WidgetRef ref, ConnectionWithDetails? scoped) {
    final l10n = AppLocalizations.of(context)!;
    final isDynamic = controller.advancedType == PfForwardType.dynamic;
    // Recording mode: the source / destination hosts are identifiers, so their
    // segments render masked and read-only (a tap runs the reveal gate).
    final recording = ref.watch(recordingModeProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Name → persists to the label column.
        ZestField(
          label: l10n.zestPfNameLabel,
          controller: controller.nameController,
          placeholder: l10n.zestPfNameHint,
          labelWidth: _pfLabelWidth(context, l10n),
          onChanged: (_) => controller.markDirty(),
        ),
        const SizedBox(height: 7),
        _PickerFieldRow(
          label: l10n.zestPfHostLabel,
          valueText: _pickerValue(ref, scoped),
          hint: l10n.zestPfChooseConnection,
          onTap: () => _pickConnection(context, controller),
        ),
        const SizedBox(height: 7),
        _TypeFieldRow(
          label: l10n.zestPfTypeLabel,
          value: controller.advancedType,
          onChanged: controller.setAdvancedType,
        ),
        const SizedBox(height: 7),
        ZestFieldGroup(
          label: l10n.zestPfSourceLabel,
          labelWidth: _pfLabelWidth(context, l10n),
          fields: [
            if (recording)
              RecordingMaskedValue(
                controller: controller.advSourceHostController,
                mask: (v) => Redactable.address(v).display,
                isMono: true,
              )
            else
              ZestField.grouped(
                label: l10n.zestPfHostLabel,
                controller: controller.advSourceHostController,
                isMono: true,
                onChanged: (_) => controller.markDirty(),
              ),
            SizedBox(
              width: _kPfPortWidth,
              child: ZestField.grouped(
                label: l10n.portForwardSourcePort,
                controller: controller.advSourcePortController,
                placeholder: '8080',
                isMono: true,
                errorText: _portError(
                    context, controller.advSourcePortController.text),
                onChanged: (_) => controller.markDirty(),
              ),
            ),
          ],
        ),
        if (!isDynamic) ...[
          const SizedBox(height: 7),
          ZestFieldGroup(
            label: l10n.zestPfDestinationLabel,
            labelWidth: _pfLabelWidth(context, l10n),
            fields: [
              if (recording)
                RecordingMaskedValue(
                  controller: controller.advDestHostController,
                  mask: (v) => Redactable.address(v).display,
                  isMono: true,
                )
              else
                ZestField.grouped(
                  label: l10n.zestPfHostLabel,
                  controller: controller.advDestHostController,
                  isMono: true,
                  onChanged: (_) => controller.markDirty(),
                ),
              SizedBox(
                width: _kPfPortWidth,
                child: ZestField.grouped(
                  label: l10n.portForwardDestinationPort,
                  controller: controller.advDestPortController,
                  placeholder: '3306',
                  isMono: true,
                  errorText: _portError(
                      context, controller.advDestPortController.text),
                  onChanged: (_) => controller.markDirty(),
                ),
              ),
            ],
          ),
        ],
        // (The SSH flags field is gone, 22 October 2026: it changed only the
        // command shown, never ZestSSH's own forward. Flags a rule was saved
        // with still show in its command.)
      ],
    );
  }

  Widget _rightColumn(
      BuildContext context, WidgetRef ref, ConnectionWithDetails? scoped) {
    final l10n = AppLocalizations.of(context)!;
    final isDynamic = controller.advancedType == PfForwardType.dynamic;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TunnelDiagram(
          type: controller.advancedType,
          devicePort:
              int.tryParse(controller.advSourcePortController.text.trim()),
          servicePort: isDynamic
              ? null
              : int.tryParse(controller.advDestPortController.text.trim()),
          serverName:
              _serverNameOf(ref, scoped, l10n.zestPfNodeServerFallback),
          serverAddress: scoped == null ? null : _hostShown(ref, scoped),
        ),
        const SizedBox(height: 14),
        ZestSectionHeader(label: l10n.zestPfOptionsLabel),
        const SizedBox(height: 4),
        // (Reconnect is gone: nothing read it, in the app's forward or in the
        // command below.) "Allow other devices" makes ZestSSH's own forward
        // listen on every address (asked when saved); "Exit if forwarding
        // fails" shapes the command alone, and says so.
        _OptionRow(
          label: l10n.zestPfOptAutoStart,
          value: controller.autoStart,
          onChanged: controller.setAutoStart,
        ),
        _OptionRow(
          label: l10n.zestPfOptGatewayPorts,
          value: controller.gatewayPorts,
          onChanged: controller.setGatewayPorts,
        ),
        _OptionRow(
          label: l10n.zestPfOptExitOnFailure,
          value: controller.exitOnFailure,
          onChanged: controller.setExitOnFailure,
        ),
        Padding(
          padding: const EdgeInsets.only(left: 2, right: 2, bottom: 4),
          child: Text(
            l10n.pfExitOnFailureCommandOnly,
            key: const ValueKey('pf-exit-command-only'),
            style: TextStyle(fontSize: 11.5, height: 1.4, color: ZestTokens.textTertiary),
          ),
        ),
      ],
    );
  }

  Widget _commandPreview(
      BuildContext context, WidgetRef ref, ConnectionWithDetails? scoped) {
    final l10n = AppLocalizations.of(context)!;
    // Painted segments take the display forms; the copied command stays real
    // (the copy button runs the reveal gate while recording).
    final shown = controller.advancedPreviewSegments(
      host: _hostShown(ref, scoped),
      username: _userShown(ref, scoped),
    );
    final real = controller.advancedPreviewSegments(
      host: _hostOf(scoped),
      username: _userOf(scoped),
    );
    return _CommandPreview(
      segments: shown,
      command: real.map((s) => s.text).join(),
      headerLabel: l10n.zestPfPreviewLabel,
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Combined-look field rows (picker / type / SSH flags)
// ══════════════════════════════════════════════════════════════════

/// One combined-look field: a rounded border enclosing a raised label cell, a
/// 1px divider, a value area, and an optional trailing glyph - the same
/// geometry as [ZestField], for a value that is a button or a bespoke input.
class _CombinedFieldRow extends StatelessWidget {
  const _CombinedFieldRow({
    required this.label,
    required this.child,
    this.trailing,
    this.onTap,
    this.labelWidth,
  });

  final String label;
  final Widget child;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// The names column's width, where the form sets its own.
  final double? labelWidth;

  @override
  Widget build(BuildContext context) {
    // As tall as the text fields beside it (40), its names' column as wide
    // as theirs: it stood 44 high, with a column of its own width.
    final row = Container(
      height: 40,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: ZestTokens.surfaceSunken,
        borderRadius: BorderRadius.circular(ZestSizing.fieldRadius),
        border: Border.all(color: ZestTokens.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            width: labelWidth ?? _pfLabelWidth(context, AppLocalizations.of(context)!),
            color: ZestTokens.surfaceRaised,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.only(left: 12, right: 12),
            child: Text(
              label,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.clip,
              style: TextStyle(
                fontSize: 13,
                color: ZestTokens.textTertiary,
              ),
            ),
          ),
          SizedBox(
            width: 1,
            child: ColoredBox(color: ZestTokens.border),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Align(alignment: Alignment.centerLeft, child: child),
            ),
          ),
          if (trailing != null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(child: trailing),
            ),
        ],
      ),
    );

    if (onTap == null) return row;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(ZestSizing.fieldRadius),
        child: row,
      ),
    );
  }
}

/// A combined-look row whose value opens the shared connection picker.
class _PickerFieldRow extends StatelessWidget {
  const _PickerFieldRow({
    required this.label,
    required this.valueText,
    required this.hint,
    required this.onTap,
    this.leading,
    this.labelWidth,
  });

  final String label;
  final String? valueText;
  final String hint;
  final VoidCallback onTap;

  /// Before the value: the chosen host's own icon.
  final Widget? leading;
  final double? labelWidth;

  @override
  Widget build(BuildContext context) {
    final selected = valueText != null;
    final text = Text(
      selected ? valueText! : hint,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 13,
        color: selected ? ZestTokens.textPrimary : ZestTokens.textTertiary,
      ),
    );
    return _CombinedFieldRow(
      label: label,
      onTap: onTap,
      labelWidth: labelWidth,
      trailing: Icon(LucideIcons.chevronDown,
          size: 15, color: ZestTokens.textSecondary),
      child: leading == null
          ? text
          : Row(children: [leading!, const SizedBox(width: 8), Flexible(child: text)]),
    );
  }
}

/// The Advanced "Type" selector, rendered as a combined-look field whose value
/// shows `Local (-L)` / `Remote (-R)` / `Dynamic (-D)` and opens a menu.
class _TypeFieldRow extends StatelessWidget {
  const _TypeFieldRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final PfForwardType value;
  final ValueChanged<PfForwardType> onChanged;

  static String labelFor(PfForwardType t, AppLocalizations l10n) => switch (t) {
        PfForwardType.local => l10n.zestPfTypeLocal,
        PfForwardType.remote => l10n.zestPfTypeRemote,
        PfForwardType.dynamic => l10n.zestPfTypeDynamic,
      };

  Future<void> _open(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final bottomRight = box.localToGlobal(
        box.size.bottomRight(Offset.zero),
        ancestor: overlay);
    final picked = await showMenu<PfForwardType>(
      context: context,
      color: AppColors.v3Elevated,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      position: RelativeRect.fromLTRB(
        topLeft.dx,
        bottomRight.dy,
        overlay.size.width - bottomRight.dx,
        overlay.size.height - bottomRight.dy,
      ),
      items: [
        for (final t in PfForwardType.values)
          PopupMenuItem<PfForwardType>(
            value: t,
            height: 38,
            child: Text(
              labelFor(t, l10n),
              style: TextStyle(
                fontSize: 13,
                fontFamily: 'JetBrainsMono',
                color: t == value
                    ? AppColors.v3AccentInk
                    : AppColors.v3TextPrimary,
              ),
            ),
          ),
      ],
    );
    if (picked != null && picked != value) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return _CombinedFieldRow(
      label: label,
      onTap: () => _open(context),
      trailing: Icon(LucideIcons.chevronDown,
          size: 15, color: ZestTokens.textSecondary),
      child: Text(
        labelFor(value, l10n),
        style: TextStyle(
          fontSize: 13,
          fontFamily: 'JetBrainsMono',
          color: ZestTokens.textPrimary,
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Options toggles
// ══════════════════════════════════════════════════════════════════

/// One "label ... switch" option row of the Advanced Options section; the
/// whole row toggles. The app's own switch, as Simple mode's.
class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(label, style: TextStyle(fontSize: 13, color: ZestTokens.textSecondary)),
            ),
            const SizedBox(width: 10),
            ZestSwitch(value: value, onChanged: onChanged),
          ],
        ),
      ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Command preview
// ══════════════════════════════════════════════════════════════════

/// The live `ssh` command preview. Renders [segments] as one mono line, dimming
/// placeholder segments (`<port>` / `<user@host>`) in place, with a copy button.
/// A non-null [headerLabel] prefixes a section header (Advanced "Command").
class _CommandPreview extends StatelessWidget {
  const _CommandPreview({
    required this.segments,
    required this.command,
    this.headerLabel,
  });

  final List<PfCommandSegment> segments;
  final String command;
  final String? headerLabel;

  @override
  Widget build(BuildContext context) {
    final box = Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceSunken,
        borderRadius: BorderRadius.circular(ZestSizing.fieldRadius),
        border: Border.all(color: ZestTokens.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  for (final s in segments)
                    TextSpan(
                      text: s.text,
                      style: TextStyle(
                        // What is still to fill, quiet but at 4.5:1 (the
                        // turned-off grey was under 3:1); its words
                        // ("<port>") say it is missing.
                        color: s.isPlaceholder
                            ? ZestTokens.textTertiary
                            : ZestTokens.textSecondary,
                      ),
                    ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12.5,
                fontFamily: 'JetBrainsMono',
                letterSpacing: 0.3,
              ),
            ),
          ),
          const SizedBox(width: 6),
          _CopyButton(command: command),
        ],
      ),
    );

    if (headerLabel == null) return box;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ZestSectionHeader(label: headerLabel!),
        const SizedBox(height: 10),
        box,
      ],
    );
  }
}

class _CopyButton extends StatelessWidget {
  const _CopyButton({required this.command});

  final String command;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return IconButton(
      icon: const Icon(LucideIcons.copy, size: 15),
      color: ZestTokens.textTertiary,
      splashRadius: 16,
      tooltip: MaterialLocalizations.of(context).copyButtonLabel,
      onPressed: () async {
        // The command carries the real user@host: reveal gate (spec 5).
        if (!await confirmRevealWhileRecording(context)) return;
        if (!context.mounted) return;
        await Clipboard.setData(ClipboardData(text: command));
        if (!context.mounted) return;
        showTopSnackBar(context, l10n.snippetsCommandCopied);
      },
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Shared small pieces
// ══════════════════════════════════════════════════════════════════

/// Live inline port validation, or null when empty/valid.
String? _portError(BuildContext context, String text) {
  final t = text.trim();
  if (t.isEmpty) return null;
  final p = int.tryParse(t);
  if (p == null || p < 1 || p > 65535) {
    return AppLocalizations.of(context)!.portForwardPortInvalid;
  }
  return null;
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: ZestTokens.textPrimary,
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Intent radio card (Simple mode) - mockup: selected bg #1f1611, border brand
// ══════════════════════════════════════════════════════════════════

class _RadioCard extends StatefulWidget {
  const _RadioCard({
    super.key,
    required this.title,
    required this.description,
    required this.tag,
    required this.isSelected,
    required this.onTap,
  });

  final String title;
  final String description;
  final String tag;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  State<_RadioCard> createState() => _RadioCardState();
}

class _RadioCardState extends State<_RadioCard> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.isSelected;
    // A choice of one: reached with Tab, said as picked or not (4.0, the
    // accessibility pass).
    return ZestPressable(
        onTap: widget.onTap,
        onHover: (h) => setState(() => _hovering = h),
        checked: selected,
        inGroup: true,
        minSize: 0,
        borderRadius: 9,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            // The theme's own accent tint (it was a dark brown in every theme).
            color: selected
                ? ZestTokens.brandSubtle
                : _hovering
                    ? ZestTokens.surfaceRaisedAlt
                    : ZestTokens.surfaceRaised,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: selected ? ZestTokens.brandBorder : ZestTokens.border),
          ),
          child: Row(
            children: [
              Icon(
                selected ? LucideIcons.circleDot : LucideIcons.circle,
                size: 17,
                color: selected ? ZestTokens.brandInk : ZestTokens.textTertiary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500, color: ZestTokens.textPrimary),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.description,
                      style: TextStyle(fontSize: 12, height: 1.3, color: ZestTokens.textSecondary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Text(
                widget.tag,
                style: TextStyle(
                  fontSize: 10,
                  fontFamily: 'JetBrainsMono',
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6,
                  color: selected ? ZestTokens.brandInk : ZestTokens.textTertiary,
                ),
              ),
            ],
          ),
        ),
    );
  }
}

/// The names' column of the form, as wide as the longest of its names at the
/// text size the app is drawn at, and at least the _kPfLabelWidth it had (a longer name was cut, as in the other forms).
double _pfLabelWidth(BuildContext context, AppLocalizations l10n) =>
    zestFieldLabelWidth(context, [l10n.zestPfNameLabel, l10n.zestPfSourceLabel, l10n.zestPfDestinationLabel, l10n.zestPfServicePortLabel, l10n.zestPfMyPortLabel, l10n.zestPfServerPortLabel, l10n.zestPfProxyPortLabel], min: _kPfLabelWidth);
