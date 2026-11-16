import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zest_ssh_core/zest_ssh_core.dart' show SSHKexType;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/core/latency_format.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/os_kind.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/monitoring_providers.dart';
import 'package:zestssh/providers/os_detection_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/os_icon.dart';
import 'package:zestssh/ui/widgets/recording_reveal_gate.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/utils/byte_size.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/ui/widgets/zest_status.dart';
import 'package:zestssh/utils/number_text.dart';

/// The Inspector's Session tab (3.0): the FOCUSED session's host and
/// connection. What was negotiated, the network and route taken, port
/// forwards, data received, and the host's load while Server Monitor watches
/// it. Nothing here is made up: a row with nothing real to say is left out.
class SessionDetailsBody extends ConsumerStatefulWidget {
  final String sessionId;
  final SessionState sessionState;

  const SessionDetailsBody({
    super.key,
    required this.sessionId,
    required this.sessionState,
  });

  @override
  ConsumerState<SessionDetailsBody> createState() => _SessionDetailsBodyState();
}

class _SessionDetailsBodyState extends ConsumerState<SessionDetailsBody> {
  void _copyToClipboard(String text, String confirmation) {
    Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      showTopSnackBar(
        context,
        confirmation,
        duration: const Duration(seconds: 2),
      );
    }
  }

  /// The real host address goes to the clipboard: reveal gate (spec 5).
  Future<void> _copyHostname(String host, String confirmation) async {
    if (!await confirmRevealWhileRecording(context, ref)) return;
    if (!mounted) return;
    _copyToClipboard(host, confirmation);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final s = widget.sessionState;
    final host = s.host ?? '--';
    final port = s.port ?? 22;
    final username = s.username;
    final connectionId = s.connectionId;

    final OsKind? osKind = connectionId != null ? ref.watch(detectedOsProvider(connectionId)) : null;
    final healthMap = ref.watch(connectionHealthProvider);
    final health = connectionId != null ? healthMap[connectionId] : null;
    final latency = health != null && health.status == ConnectionHealth.online ? health.latencyMs : null;
    final samples = connectionId == null ? const <int>[] : (ref.watch(latencySamplesProvider)[connectionId] ?? const <int>[]);

    // What was negotiated, from the SSH core's diagnostics: null until the
    // key exchange is done and after a disconnect, so each row is left out
    // when there is nothing real to say.
    final shell = s.session?.shell;
    final ssh = shell is SshService ? shell : null;
    final kex = ssh?.negotiatedKex;
    final cipher = ssh?.negotiatedCipher;
    final mac = ssh?.negotiatedMac;
    final hostKeyAlg = ssh?.negotiatedHostKeyAlgorithm;
    final serverVersion = ssh?.serverVersion;

    // The network and route taken, now that a host can have one per network.
    final route = connectionId != null ? ref.watch(sessionRouteProvider(connectionId)).valueOrNull : null;

    // The saved forwards of this host that are running.
    final activeForwardIds = ref.watch(activeForwardIdsProvider);
    final rules = connectionId != null
        ? (ref.watch(portForwardRulesForConnectionProvider(connectionId)).valueOrNull ?? const <PortForwardRule>[])
        : const <PortForwardRule>[];
    final activeForwards = rules.where((r) => activeForwardIds.contains(r.id)).toList();

    // How it signed in: the host's identity where it has one, else the way.
    final item = connectionId == null
        ? null
        : (ref.watch(connectionsWithDetailsProvider).valueOrNull ?? const [])
            .where((c) => c.connection.id == connectionId)
            .firstOrNull;
    final identity = item?.identity;
    final signedIn = identity != null
        ? (identity.keyType == null ? identity.label : '${identity.label} (${identity.keyType})')
        : _authWords(l10n, ssh?.signedInWith);

    final since = s.session?.startedAt.toLocal();
    final address = '${username == null || username.isEmpty ? '' : '${Redactable.username(username).displayIn(ref)}@'}'
        '${Redactable.address(host).displayIn(ref)}:$port';

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
      children: [
        // ── Connection ──
        _Head(l10n.inspectorConnection),
        _InfoRow(label: l10n.inspectorHost, value: Redactable.host(s.connectionLabel).displayIn(ref)),
        _InfoRow(
          label: l10n.inspectorAddress,
          value: address,
          mono: true,
          trailing: _HoverIconButton(
            icon: LucideIcons.copy,
            size: 13,
            tooltip: l10n.sessionDetailsCopyHostname,
            onTap: () => _copyHostname(host, l10n.sessionDetailsHostnameCopied),
          ),
        ),
        if (signedIn != null) _InfoRow(label: l10n.inspectorSignedInWith, value: signedIn),
        if (route != null)
          _InfoRow(label: l10n.sessionDetailsNetwork, value: Redactable.network(route.network.name).displayIn(ref)),
        if (route != null)
          _InfoRow(
            label: l10n.sessionDetailsRoute,
            value: '${Redactable.address(route.address).displayIn(ref)}:${route.port}',
            mono: true,
          ),
        if (route != null && route.jumpChain.isNotEmpty)
          _InfoRow(label: l10n.sessionDetailsVia, value: _jumpChainLabel(route.jumpChain)),
        if (activeForwards.isNotEmpty)
          _ForwardsRow(label: l10n.sessionDetailsPortForwards, forwards: activeForwards),

        // ── Status ──
        _Head(l10n.inspectorStatus),
        _InfoRow(
          label: l10n.inspectorState,
          value: '',
          // Each of the four states in its own words: disconnected and error
          // said Connecting before.
          trailing: ZestStatusPill(
            key: const ValueKey('inspector-state'),
            kind: switch (s.status) {
              SessionStatus.connected => ZestStatusKind.healthy,
              SessionStatus.connecting => ZestStatusKind.pending,
              SessionStatus.disconnected => ZestStatusKind.neutral,
              SessionStatus.error => ZestStatusKind.critical,
            },
            label: switch (s.status) {
              SessionStatus.connected => l10n.sessionInfoStatusConnected,
              SessionStatus.connecting => l10n.sessionInfoStatusConnecting,
              SessionStatus.disconnected => l10n.sessionInfoStatusDisconnected,
              SessionStatus.error => l10n.sessionInfoStatusError,
            },
          ),
        ),
        if (since != null)
          _InfoRow(
            label: l10n.inspectorSince,
            value: '${since.hour.toString().padLeft(2, '0')}:${since.minute.toString().padLeft(2, '0')}',
            mono: true,
          ),
        if (latency != null) ...[
          _InfoRow(
            label: l10n.sessionDetailsLatency,
            value: '${latencyText(latency)} ms',
            mono: true,
            valueColor: _latencyColor(latency),
            last: samples.length >= 2,
          ),
          if (samples.length >= 2) _LatencyBars(samples: samples),
        ],
        // Data received: isolated so heavy output only rebuilds this row.
        Consumer(
          builder: (context, r, _) => _InfoRow(
            label: l10n.sessionDetailsDataReceived,
            value: _formatBytes(r.watch(sessionBytesReceivedProvider(widget.sessionId))),
            mono: true,
          ),
        ),

        // ── Load (Server Monitor) ──
        _Head(l10n.inspectorLoad, note: l10n.monitorTitle),
        ..._loadRows(l10n),

        // ── Details ──
        _Head(l10n.inspectorDetails),
        if (serverVersion != null && serverVersion.isNotEmpty)
          _InfoRow(label: l10n.sessionDetailsProtocol, value: serverVersion, mono: true)
        else if (s.session?.shell.isEncryptedSsh ?? false)
          _InfoRow(label: l10n.sessionDetailsProtocol, value: 'SSH'),
        if (kex != null && kex.isNotEmpty)
          _InfoRow(
            label: l10n.sessionDetailsKeyExchange,
            value: kex,
            mono: true,
            // A hybrid post-quantum exchange earns a badge: the one fact
            // about the crypto a person may want to check at a glance.
            trailing: SSHKexType.isPostQuantumName(kex)
                ? _PostQuantumTag(
                    label: l10n.sessionDetailsPostQuantum,
                    tooltip: l10n.sessionDetailsPostQuantumTooltip,
                  )
                : null,
          ),
        if (cipher != null && cipher.isNotEmpty)
          _InfoRow(label: l10n.sessionDetailsCipher, value: cipher, mono: true),
        if (mac != null && mac.isNotEmpty) _InfoRow(label: l10n.sessionDetailsMac, value: mac, mono: true),
        if (hostKeyAlg != null && hostKeyAlg.isNotEmpty)
          _InfoRow(label: l10n.sessionDetailsHostKey, value: hostKeyAlg, mono: true),
        if (osKind != null && osKind != OsKind.unknown)
          _InfoRow(
            label: l10n.sessionDetailsOs,
            value: OsIconWidget.labelForOs(osKind),
            leading: OsIconWidget(kind: osKind, size: 14),
          ),
        _InfoRow(label: l10n.inspectorTerminal, value: 'xterm-256color', mono: true),
        _InfoRow(label: l10n.inspectorEncoding, value: 'UTF-8', mono: true, last: true),
      ],
    );
  }

  /// The way a session signed in, in words; null for a way not known.
  static String? _authWords(AppLocalizations l10n, String? method) => switch (method) {
        'publickey' => l10n.inspectorSignedInKey,
        'password' => l10n.inspectorSignedInPassword,
        'keyboard-interactive' => l10n.inspectorSignedInKeyboard,
        _ => null,
      };

  /// Map jump-host connection ids to human labels (falling back to the raw id
  /// when a hop's connection can't be resolved) and join them into a route.
  String _jumpChainLabel(List<String> jumpChain) {
    final conns = ref.watch(connectionsWithDetailsProvider).valueOrNull;
    final labelById = <String, String>{};
    if (conns != null) {
      for (final c in conns) {
        // Painted, so each hop goes through the redaction toolkit.
        labelById[c.connection.id] = c.connection.label.isNotEmpty
            ? Redactable.host(c.connection.label).displayIn(ref)
            : Redactable.address(c.connection.host).displayIn(ref);
      }
    }
    return jumpChain.map((id) => labelById[id] ?? id).join('  →  ');
  }

  Color _latencyColor(int ms) {
    if (ms < 100) return AppColors.v3Success;
    if (ms < 300) return AppColors.v3Warning;
    return AppColors.v3Error;
  }

  // ── Load (Server Monitor) ─────────────────────────────────────

  List<Widget> _loadRows(AppLocalizations l10n) {
    final connectionId = widget.sessionState.connectionId;
    final stats = connectionId == null ? null : ref.watch(serverStatsProvider.select((m) => m[connectionId]));
    if (stats == null) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(l10n.inspectorLoadNotWatched, style: TextStyle(fontSize: 12, color: AppColors.v3TextTertiary)),
        ),
      ];
    }
    String pct(double v) => formatPercentNumber(v, l10n: l10n);
    final at = stats.collectedAt.toLocal();
    final hh = at.hour.toString().padLeft(2, '0');
    final mm = at.minute.toString().padLeft(2, '0');
    final ram = stats.ramPercent;
    return [
      if (stats.cpuPercent != null)
        _InfoRow(label: l10n.inspectorLoadCpu, value: pct(stats.cpuPercent!), mono: true, valueColor: _loadColor(stats.cpuPercent!)),
      if (ram != null) _InfoRow(label: l10n.inspectorLoadMemory, value: pct(ram), mono: true, valueColor: _loadColor(ram)),
      if (stats.diskPercent != null)
        _InfoRow(label: l10n.inspectorLoadDisk, value: pct(stats.diskPercent!), mono: true, valueColor: _loadColor(stats.diskPercent!)),
      if (stats.loadAverage != null && stats.loadAverage!.isNotEmpty)
        _InfoRow(
          label: l10n.inspectorLoadAverage,
          value: stats.loadAverage!.map((v) => formatDecimal(v, digits: 2, l10n: l10n)).join('  '),
          mono: true,
        ),
      if (stats.uptime != null && stats.uptime!.isNotEmpty) _InfoRow(label: l10n.inspectorLoadUptime, value: stats.uptime!),
      _InfoRow(label: l10n.inspectorLoadAsOf, value: '$hh:$mm', mono: true),
    ];
  }

  /// The one status palette: under 70% fine, under 90% warn, else critical.
  Color _loadColor(double pct) {
    if (pct < 70) return AppColors.v3TextPrimary;
    if (pct < 90) return AppColors.v3Warning;
    return AppColors.v3Error;
  }

  /// Format a byte count into a compact human-readable string, in the app's
  /// language (its units and decimal mark).
  String _formatBytes(int bytes) => formatByteSize(bytes, digits: SizeDigits.oneThenTwo);
}

// ═══════════════════════════════════════════════════════════════════
// Enums
// ═══════════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════════
// Sub-widgets
// ═══════════════════════════════════════════════════════════════════

/// Key-value info row for the Host Info section.
/// Small accent pill on the key-exchange row for a hybrid post-quantum
/// exchange (mlkem768x25519 / sntrup761x25519), with the why on hover.
class _PostQuantumTag extends StatelessWidget {
  const _PostQuantumTag({required this.label, required this.tooltip});

  final String label;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.v3AccentPrimary;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: accent.withValues(alpha: 0.32)),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
            color: AppColors.v3AccentInk,
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final bool mono;
  final Widget? trailing;
  final Widget? leading;
  final Color? valueColor;

  /// The last row of its section: no hairline under it.
  final bool last;

  const _InfoRow({
    required this.label,
    required this.value,
    this.mono = false,
    this.trailing,
    this.leading,
    this.valueColor,
    this.last = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 34),
      padding: const EdgeInsets.symmetric(vertical: 7),
      decoration: BoxDecoration(
        border: last ? null : Border(bottom: BorderSide(color: AppColors.v3BorderSubtle)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 12.5, color: AppColors.v3TextTertiary),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (leading != null) ...[
                  leading!,
                  const SizedBox(width: 6),
                ],
                if (value.isNotEmpty)
                  Flexible(
                    child: Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: mono ? 11.5 : 12.5,
                        fontFamily: mono ? 'JetBrainsMono' : null,
                        color: valueColor ?? AppColors.v3TextPrimary,
                      ),
                    ),
                  ),
                if (trailing != null) ...[
                  if (value.isNotEmpty) const SizedBox(width: 6),
                  trailing!,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A section of the Session tab, headed as the Blueprint heads them.
class _Head extends StatelessWidget {
  const _Head(this.label, {this.note});
  final String label;
  final String? note;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 16),
        child: ZestSectionHeader(
          label: label,
          trailing: note == null ? null : Text(note!, style: TextStyle(fontSize: 11.5, color: AppColors.v3TextTertiary)),
        ),
      );
}

/// The latency over the last checks, as small bars (the highest the tallest).
class _LatencyBars extends StatelessWidget {
  const _LatencyBars({required this.samples});
  final List<int> samples;

  @override
  Widget build(BuildContext context) {
    final top = samples.reduce((a, b) => a > b ? a : b).clamp(1, 1 << 30);
    return Container(
      key: const ValueKey('inspector-latency-bars'),
      height: 34,
      padding: const EdgeInsets.only(top: 6, bottom: 8),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.v3BorderSubtle))),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final v in samples)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1.5),
                child: FractionallySizedBox(
                  heightFactor: (0.3 + 0.7 * v / top).clamp(0.3, 1.0),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: (v < 100 ? AppColors.v3Success : v < 300 ? AppColors.v3Warning : AppColors.v3Error)
                          .withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The last latencies each host's checks measured (up to 14), for the
/// Inspector's bars: kept while the app runs, never saved.
final latencySamplesProvider = StateNotifierProvider<LatencySamples, Map<String, List<int>>>((ref) {
  final samples = LatencySamples();
  ref.listen<Map<String, HealthCheckResult>>(connectionHealthProvider, (previous, next) {
    for (final e in next.entries) {
      final ms = e.value.latencyMs;
      if (ms == null || e.value.status != ConnectionHealth.online) continue;
      if (previous?[e.key]?.checkedAt == e.value.checkedAt) continue;
      samples.add(e.key, ms);
    }
  }, fireImmediately: true);
  return samples;
});

class LatencySamples extends StateNotifier<Map<String, List<int>>> {
  LatencySamples() : super(const {});

  static const keep = 14;

  void add(String connectionId, int ms) {
    final list = [...(state[connectionId] ?? const <int>[]), ms];
    state = {...state, connectionId: list.length > keep ? list.sublist(list.length - keep) : list};
  }
}

/// A labeled block listing the active port forwards for the session - one
/// mono line per forward so multiple tunnels stay readable under one label.
/// Drawn as an [_InfoRow] is (its label's size and colour, the values at the
/// right, a hairline under it): it was smaller, ruleless and at the left
/// among its siblings (found in a design audit).
class _ForwardsRow extends ConsumerWidget {
  final String label;
  final List<PortForwardRule> forwards;

  const _ForwardsRow({
    required this.label,
    required this.forwards,
  });

  /// Single-letter mnemonic matching the ssh flags (-L / -R / -D).
  String _typeLetter(String type) {
    switch (type) {
      case 'remote':
        return 'R';
      case 'dynamic':
        return 'D';
      default:
        return 'L';
    }
  }

  String _endpoint(PortForwardRule r) {
    switch (r.type) {
      case 'remote':
        return '${r.remoteHost}:${r.remotePort} → ${r.bindPort}';
      case 'dynamic':
        return 'SOCKS5 :${r.bindPort}';
      default:
        return '${r.bindPort} → ${r.remoteHost}:${r.remotePort}';
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      key: const ValueKey('inspector-port-forwards'),
      constraints: const BoxConstraints(minHeight: 34),
      padding: const EdgeInsets.symmetric(vertical: 7),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.v3BorderSubtle)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 12.5, color: AppColors.v3TextTertiary),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < forwards.length; i++)
                  Padding(
                    padding: EdgeInsets.only(top: i == 0 ? 0 : 3),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                          _typeLetter(forwards[i].type),
                          style: TextStyle(
                            fontSize: 11.5,
                            fontFamily: 'JetBrainsMono',
                            fontWeight: FontWeight.w600,
                            color: AppColors.v3AccentInk,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          // Recording mode: the endpoint names the remote host
                          // (`192.168.10.31:5432 -> 8080`), so it goes through the
                          // free-text rule, which masks an address-shaped or
                          // registered host wherever it sits in the line.
                          child: Text(
                            Redactable.freeText(_endpoint(forwards[i])).displayIn(ref),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              fontSize: 11.5,
                              fontFamily: 'JetBrainsMono',
                              color: AppColors.v3TextPrimary,
                            ),
                          ),
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

/// Small icon button with hover highlight.
class _HoverIconButton extends StatefulWidget {
  final IconData icon;
  final double size;
  final String? tooltip;
  final VoidCallback onTap;

  const _HoverIconButton({
    required this.icon,
    required this.size,
    this.tooltip,
    required this.onTap,
  });

  @override
  State<_HoverIconButton> createState() => _HoverIconButtonState();
}

class _HoverIconButtonState extends State<_HoverIconButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    Widget btn = MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: _hovering
                ? AppColors.v3Surface.withValues(alpha: 0.6)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Icon(
            widget.icon,
            size: widget.size,
            color: _hovering ? AppColors.v3TextPrimary : AppColors.v3TextSecondary,
          ),
        ),
      ),
    );
    if (widget.tooltip != null) {
      btn = Tooltip(message: widget.tooltip!, child: btn);
    }
    return btn;
  }
}
