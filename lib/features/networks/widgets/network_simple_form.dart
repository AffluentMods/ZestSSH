import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../models/redactable.dart';
import '../../../theme/zest_tokens.dart';
import '../../../ui/widgets/connection_picker_dialog.dart';
import '../../../ui/widgets/recording_masked_field.dart';
import '../../../ui/widgets/redacted_text.dart';
import '../../../ui/widgets/zest_button.dart';
import '../../../ui/widgets/zest_dialog.dart';
import '../../../providers/settings_providers.dart' show recordingModeProvider;
import '../../../ui/widgets/zest_section_header.dart';
import '../engine/network_state.dart' show wifiNamesReadHere;
import '../models/network_trigger.dart';
import '../state/network_controller.dart';
import 'network_form_fields.dart';
import 'network_rule_words.dart';
import 'trigger_summary.dart' show maskedCidr;

/// Simple mode: the name;
/// DETECT WHEN, every rule as a row with quick ways to add more; how hosts
/// are reached on this network (directly, or through a jump host); the hosts
/// with a rule of their own; the look. Everything a network holds is in
/// sight here; a host rule's own fields are Advanced's (its Edit goes there).
class NetworkSimpleForm extends ConsumerWidget {
  const NetworkSimpleForm({super.key, required this.controller});

  final NetworkEditController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final isFallback = controller.isFallback;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NetworkNameField(controller: controller),
          const SizedBox(height: 22),
          ZestSectionHeader(
            label: l10n.netEdDetectWhen,
            trailing: isFallback
                ? null
                : Text(l10n.netEdAnyRule, style: TextStyle(fontSize: 12, color: ZestTokens.textTertiary)),
          ),
          if (isFallback)
            Text(l10n.zestNetworkFallbackWhen, style: TextStyle(fontSize: 13, color: ZestTokens.textSecondary))
          else
            _Rules(controller: controller),
          const SizedBox(height: 22),
          ZestSectionHeader(label: l10n.netEdReachHosts),
          _ReachHosts(controller: controller),
          const SizedBox(height: 22),
          _HostRules(controller: controller),
          const SizedBox(height: 22),
          ZestSectionHeader(label: l10n.netEdLook),
          _LookRow(controller: controller),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Detect when: the rules, and quick ways to add one
// ══════════════════════════════════════════════════════════════════

class _Rules extends StatelessWidget {
  const _Rules({required this.controller});

  final NetworkEditController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final hasWifi = controller.triggers.any((t) => t.kind == TriggerKind.ssid);
    final error = controller.triggersError;
    Widget chip(String key, String label, VoidCallback onTap) => ZestButton(
          key: ValueKey('network-add-$key'),
          label: label,
          icon: LucideIcons.plus,
          variant: ZestButtonVariant.secondary,
          onPressed: onTap,
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final draft in controller.triggers)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _RuleRow(
              key: ObjectKey(draft),
              draft: draft,
              onChanged: controller.markDirty,
              onRemove: () => controller.removeTrigger(draft),
            ),
          ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(error, style: TextStyle(fontSize: 12, color: ZestTokens.statusCritical)),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            chip('cellular', l10n.netEdAddCellular, () => controller.addTrigger(TriggerKind.cellular)),
            chip('ethernet', l10n.netEdAddEthernet, () => controller.addConnectivity(ConnectivityKind.ethernet)),
            chip('ip', l10n.netEdAddIpRange, () => controller.addTrigger(TriggerKind.subnet)),
            chip('tailscale', l10n.netEdAddTailscale, () => controller.addSubnet(tailscaleCidr)),
            chip('vpn', l10n.netEdAddVpn, () => controller.addConnectivity(ConnectivityKind.vpn)),
            // A Wi-Fi name only where it is read: never on a phone.
            if (wifiNamesReadHere)
              chip('wifi', hasWifi ? l10n.netEdAddAnotherWifi : l10n.netEdAddWifi,
                  () => controller.addTrigger(TriggerKind.ssid)),
          ],
        ),
        if (!wifiNamesReadHere) ...[
          const SizedBox(height: 10),
          Text(defaultTargetPlatform == TargetPlatform.macOS ? l10n.netWifiNamesNotOnMac : l10n.netWifiNamesNotOnPhones,
              style: TextStyle(fontSize: 12, height: 1.4, color: ZestTokens.textTertiary)),
        ],
      ],
    );
  }
}

/// One rule: what it checks, its value where it has one, and remove.
class _RuleRow extends ConsumerWidget {
  const _RuleRow({super.key, required this.draft, required this.onChanged, required this.onRemove});

  final TriggerDraft draft;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final text = draft.textController;
    final tailscale = draft.kind == TriggerKind.subnet && isTailscaleCidr(text?.text ?? '');
    final (icon, label) = switch (draft.kind) {
      TriggerKind.ssid => (LucideIcons.wifi, l10n.netEdWifiLabel),
      TriggerKind.subnet when tailscale => (LucideIcons.shieldCheck, l10n.netRuleTailscale),
      TriggerKind.subnet => (LucideIcons.network, l10n.netEdIpLabel),
      TriggerKind.cellular => (LucideIcons.signal, l10n.netRuleCellular),
      TriggerKind.connectivity => (
          switch (draft.connectivityKind) {
            ConnectivityKind.ethernet => LucideIcons.plug,
            ConnectivityKind.vpn => LucideIcons.shield,
            ConnectivityKind.cellular => LucideIcons.signal,
            _ => LucideIcons.wifi,
          },
          networkRuleWords(l10n, draft.toTrigger()),
        ),
    };
    final editable = text != null && !tailscale;
    final error = editable && text.text.trim().isNotEmpty ? draft.fieldError(l10n) : null;
    final mono = draft.kind == TriggerKind.subnet;

    Widget value() {
      if (!editable) {
        return tailscale
            ? Text(tailscaleCidr,
                style: TextStyle(fontSize: 12, fontFamily: 'JetBrainsMono', color: ZestTokens.textTertiary))
            : const SizedBox.shrink();
      }
      final style = TextStyle(
        fontSize: 13,
        fontFamily: mono ? 'JetBrainsMono' : null,
        color: ZestTokens.textPrimary,
      );
      final field = TextField(
        controller: text,
        onChanged: (_) => onChanged(),
        style: style,
        decoration: InputDecoration(
          isDense: true,
          isCollapsed: true,
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          disabledBorder: InputBorder.none,
          errorBorder: InputBorder.none,
          focusedErrorBorder: InputBorder.none,
          hintText: mono ? '10.50.0.0/24' : AppLocalizations.of(context)!.networkIconWork,
          hintStyle: style.copyWith(color: ZestTokens.textPlaceholder),
        ),
      );
      // A Wi-Fi name and an address are masked while recording.
      if (ref.watch(recordingModeProvider)) {
        return RecordingMaskedValue(
          controller: text,
          mask: (v) => mono ? maskedCidr(v) : Redactable.network(v).display,
          isMono: mono,
        );
      }
      return field;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          constraints: const BoxConstraints(minHeight: 42),
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
          decoration: BoxDecoration(
            color: ZestTokens.surfaceSunken,
            borderRadius: BorderRadius.circular(ZestSizing.fieldRadius),
            border: Border.all(color: error != null ? ZestTokens.statusCritical : ZestTokens.border),
          ),
          child: Row(
            children: [
              Icon(icon, size: 15, color: ZestTokens.textSecondary),
              const SizedBox(width: 10),
              Text(label, style: TextStyle(fontSize: 13, color: ZestTokens.textSecondary)),
              const SizedBox(width: 12),
              Expanded(child: value()),
              IconButton(
                icon: const Icon(LucideIcons.x, size: 14),
                color: ZestTokens.textTertiary,
                splashRadius: 15,
                tooltip: l10n.networkEditorRemoveTrigger,
                onPressed: onRemove,
              ),
            ],
          ),
        ),
        if (tailscale)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 2),
            child: Text(l10n.netEdTailscaleNote,
                style: TextStyle(fontSize: 11.5, height: 1.35, color: ZestTokens.textTertiary)),
          ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 2),
            child: Text(error, style: TextStyle(fontSize: 11.5, color: ZestTokens.statusCritical)),
          ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// How hosts are reached on this network
// ══════════════════════════════════════════════════════════════════

class _ReachHosts extends ConsumerStatefulWidget {
  const _ReachHosts({required this.controller});

  final NetworkEditController controller;

  @override
  ConsumerState<_ReachHosts> createState() => _ReachHostsState();
}

class _ReachHostsState extends ConsumerState<_ReachHosts> {
  /// "Via a jump host" chosen before a host is: the picker shows, nothing
  /// is saved yet.
  bool _choosing = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final c = widget.controller;
    final host = hostById(ref, c.bringUpVpn);
    final via = c.bringUpVpn != null || _choosing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _Choice(
                key: const ValueKey('network-reach-direct'),
                label: l10n.netEdDirectly,
                selected: !via,
                onTap: () {
                  setState(() => _choosing = false);
                  if (c.bringUpVpn != null) c.setBringUpVpn(null);
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _Choice(
                key: const ValueKey('network-reach-jump'),
                label: l10n.netEdViaJump,
                selected: via,
                onTap: () => setState(() => _choosing = true),
              ),
            ),
          ],
        ),
        // (Via Tailscale is not offered: nothing in ZestSSH reaches a host
        // through Tailscale by itself.)
        if (via) ...[
          const SizedBox(height: 10),
          NetworkJumpHostField(hostId: c.bringUpVpn, onChanged: c.setBringUpVpn),
        ],
        const SizedBox(height: 10),
        Text(
          host != null ? l10n.netEdViaLine(hostNameShown(ref, host)) : l10n.netEdDirectLine,
          style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textSecondary),
        ),
      ],
    );
  }
}

/// One of two choices, side by side: the chosen one in the accent.
class _Choice extends StatelessWidget {
  const _Choice({super.key, required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? ZestTokens.brandSubtle : ZestTokens.surfaceRaised,
              borderRadius: BorderRadius.circular(ZestSizing.fieldRadius),
              border: Border.all(color: selected ? ZestTokens.brandBorder : ZestTokens.border),
            ),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected ? ZestTokens.brandInk : ZestTokens.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Host rules
// ══════════════════════════════════════════════════════════════════

class _HostRules extends ConsumerWidget {
  const _HostRules({required this.controller});

  final NetworkEditController controller;

  Future<void> _add(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await ConnectionPickerDialog.show(context, title: l10n.netEdAddHostRule);
    final host = picked.connection;
    if (host == null) return;
    // Its fields (address, port, jump hosts, not reached here) are
    // Advanced's host table: the rule is added there, ready to fill.
    controller.addOverride(host.connection.id);
    controller.setMode(EditorMode.advanced);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final rules = controller.overrides.where((o) => !o.isEmptyDraft).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ZestSectionHeader(
          label: l10n.netEdHostRules,
          count: rules.length,
          actionLabel: l10n.netEdAddHostRule,
          onAction: () => _add(context),
        ),
        if (rules.isEmpty)
          Text(l10n.netEdHostRulesNone, style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textSecondary))
        else
          for (final rule in rules)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _HostRuleRow(rule: rule, onEdit: () => controller.setMode(EditorMode.advanced)),
            ),
      ],
    );
  }
}

/// One host's rule on this network: the host, what is different, Edit.
class _HostRuleRow extends ConsumerWidget {
  const _HostRuleRow({required this.rule, required this.onEdit});

  final HostOverrideDraft rule;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final host = hostById(ref, rule.hostId);
    final address = rule.addressController.text.trim();
    final port = rule.portController.text.trim();
    final what = rule.skip
        ? l10n.netEdHostSkipped
        : rule.jumpChain.isNotEmpty
            ? l10n.netEdHostThrough([
                for (final id in rule.jumpChain)
                  if (hostById(ref, id) case final h?) hostNameShown(ref, h),
              ].join(' → '))
            : address.isNotEmpty || port.isNotEmpty
                ? l10n.netEdHostAt(
                    '${address.isEmpty ? '' : Redactable.address(address).displayIn(ref)}${port.isEmpty ? '' : ':$port'}')
                : l10n.netEdHostDirect;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceRaised,
        borderRadius: BorderRadius.circular(ZestSizing.fieldRadius),
        border: Border.all(color: ZestTokens.border),
      ),
      child: Row(
        children: [
          if (host != null) ...[
            NetworkHostIcon(host: host, size: 20),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  host == null ? rule.hostId : hostNameShown(ref, host),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary),
                ),
                const SizedBox(height: 2),
                Text(what,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: ZestTokens.textSecondary)),
              ],
            ),
          ),
          ZestButton(
            label: l10n.netEdHostEdit,
            variant: ZestButtonVariant.ghost,
            onPressed: onEdit,
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Look: the icon and its colour
// ══════════════════════════════════════════════════════════════════

class _LookRow extends StatelessWidget {
  const _LookRow({required this.controller});

  final NetworkEditController controller;

  Future<void> _change(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    await ZestDialogShell.showModal<void>(
      context,
      size: ZestModalSize.standard,
      tone: ZestDialogTone.neutral,
      title: l10n.netEdLookTitle,
      icon: controller.icon,
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            ZestSectionHeader(label: l10n.networkEditorIcon),
            NetworkIconGrid(controller: controller),
            if (!controller.isFallback) ...[
              const SizedBox(height: 18),
              ZestSectionHeader(label: l10n.networkEditorColor),
              NetworkColorField(controller: controller),
            ],
          ],
        ),
      ),
      secondaryAction: (
        label: MaterialLocalizations.of(context).closeButtonLabel,
        onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final color = controller.colorValue != null ? Color(controller.colorValue!) : controller.color.value;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceRaised,
        borderRadius: BorderRadius.circular(ZestSizing.fieldRadius),
        border: Border.all(color: ZestTokens.border),
      ),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Icon(controller.icon, size: 16, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              networkIconLabel(l10n, controller.icon),
              style: TextStyle(fontSize: 13.5, color: ZestTokens.textPrimary),
            ),
          ),
          ZestButton(
            key: const ValueKey('network-look-change'),
            label: l10n.netEdChange,
            variant: ZestButtonVariant.secondary,
            onPressed: () => _change(context),
          ),
        ],
      ),
    );
  }
}
