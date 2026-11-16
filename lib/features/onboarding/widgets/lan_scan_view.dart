import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/features/onboarding/data/lan_scan_service.dart';
import 'package:zestssh/core/latency_format.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';

/// Explicit, bounded, cancellable scan of the current /24 for SSH servers.
///
/// Nothing is probed until the user taps Start; the scope is shown up-front.
/// Found hosts can be selected and added as connections. Designed to sit in a
/// bounded box (uses an [Expanded] results list).
class LanScanView extends ConsumerStatefulWidget {
  const LanScanView({super.key, required this.onAdded, this.service});

  /// Called after connections are created from the selected hits.
  /// [added] = created, [failedLimit] = blocked by the free-tier limit.
  final void Function(int added, int failedLimit) onAdded;

  /// What finds the network and probes it; a test's own stands in.
  final LanScanService? service;

  @override
  ConsumerState<LanScanView> createState() => _LanScanViewState();
}

enum _Phase { resolving, ready, scanning, done, unavailable }

class _LanScanViewState extends ConsumerState<LanScanView> {
  late final _service = widget.service ?? LanScanService();
  _Phase _phase = _Phase.resolving;
  LanScanScope? _scope;
  final List<LanScanHit> _hits = [];
  final Set<String> _selected = {};
  int _scanned = 0;
  int _total = 0;
  bool _adding = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void dispose() {
    _service.cancel();
    super.dispose();
  }

  Future<void> _resolve() async {
    final scope = await _service.resolveScope();
    if (!mounted) return;
    setState(() {
      _scope = scope;
      _phase = scope == null ? _Phase.unavailable : _Phase.ready;
    });
  }

  Future<void> _startScan() async {
    final scope = _scope;
    if (scope == null) return;
    setState(() {
      _phase = _Phase.scanning;
      _hits.clear();
      _selected.clear();
      _scanned = 0;
      _total = scope.hostCount;
    });
    await _service.scan(
      scope: scope,
      onHit: (hit) {
        if (!mounted) return;
        setState(() {
          _hits.add(hit);
          _selected.add(hit.host);
        });
      },
      onProgress: (scanned, total) {
        if (!mounted) return;
        setState(() {
          _scanned = scanned;
          _total = total;
        });
      },
    );
    if (!mounted) return;
    setState(() => _phase = _Phase.done);
  }

  void _stopScan() {
    _service.cancel();
    setState(() => _phase = _Phase.done);
  }

  Future<void> _addSelected() async {
    if (_selected.isEmpty || _adding) return;
    setState(() => _adding = true);
    final crud = ref.read(connectionCrudProvider);
    var added = 0;
    var failedLimit = 0;
    var limitHit = false;
    for (final host in _selected) {
      if (limitHit) {
        failedLimit++;
        continue;
      }
      try {
        await crud.create(label: host, host: host, port: 22);
        added++;
      } on StateError {
        limitHit = true;
        failedLimit++;
      }
    }
    if (!mounted) return;
    setState(() => _adding = false);
    widget.onAdded(added, failedLimit);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    if (_phase == _Phase.resolving) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_phase == _Phase.unavailable) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.wifiOff,
                  size: 44,
                  color: AppColors.textSecondary.withValues(alpha: 0.5)),
              const SizedBox(height: 12),
              Text(
                l10n.networkScanUnavailable,
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      );
    }

    final scope = _scope!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Scope banner - shown before AND during scanning so the user always
        // sees exactly what is being touched.
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.divider, width: 0.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(LucideIcons.network,
                      size: 18, color: AppColors.accentInk),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.networkScanScope(scope.cidr),
                      style: TextStyle(
                        fontSize: 13,
                        color: AppColors.onSurface,
                        height: 1.3,
                      ),
                    ),
                  ),
                ],
              ),
              if (_phase == _Phase.ready) ...[
                const SizedBox(height: 6),
                Text(
                  l10n.networkScanExplainAction,
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),

        if (_phase == _Phase.scanning)
          _ProgressRow(
            label: l10n.networkScanProgress(_scanned, _total),
            onStop: _stopScan,
            stopLabel: l10n.networkScanStop,
          )
        // What a scan found, once one has run: before Start it said "No SSH
        // servers responded" when nothing had been asked (seen in an
        // emulator check), as a computer's scan does not.
        else if (_phase == _Phase.done)
          Text(
            l10n.networkScanFound(_hits.length),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.onSurface,
            ),
          ),
        const SizedBox(height: 8),

        Expanded(
          child: _hits.isEmpty
              ? Center(
                  child: Text(
                    _phase == _Phase.done
                        ? l10n.networkScanEmpty
                        : '',
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                )
              : ListView.builder(
                  itemCount: _hits.length,
                  itemBuilder: (context, i) {
                    final hit = _hits[i];
                    final sel = _selected.contains(hit.host);
                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      color: sel
                          ? AppColors.brandOrange.withValues(alpha: 0.08)
                          : AppColors.surface,
                      child: CheckboxListTile(
                        value: sel,
                        onChanged: (v) => setState(() {
                          if (v == true) {
                            _selected.add(hit.host);
                          } else {
                            _selected.remove(hit.host);
                          }
                        }),
                        activeColor: AppColors.brandOrange,
                        // A scan hit is an address (masked in recording
                        // mode); selection still keys on the real host.
                        title: RedactedText(
                          Redactable.address(hit.host),
                          style: const TextStyle(
                            fontFamily: 'JetBrainsMono',
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text('${latencyText(hit.latencyMs)} ms · port 22',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.textSecondary,
                            )),
                        secondary: Icon(LucideIcons.server,
                            color: AppColors.accentInk),
                      ),
                    );
                  },
                ),
        ),
        const SizedBox(height: 12),

        if (_phase == _Phase.ready)
          FilledButton.icon(
            onPressed: _startScan,
            icon: const Icon(LucideIcons.radar),
            label: Text(l10n.networkScanStart),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.brandOrange,
              minimumSize: const Size(double.infinity, 48),
            ),
          )
        else if (_phase == _Phase.done) ...[
          if (_selected.isNotEmpty)
            FilledButton.icon(
              onPressed: _adding ? null : _addSelected,
              icon: _adding
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(LucideIcons.plus),
              label: Text(l10n.networkScanAddSelected(_selected.length)),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.brandOrange,
                minimumSize: const Size(double.infinity, 48),
              ),
            ),
          if (_selected.isNotEmpty) const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _startScan,
            icon: const Icon(LucideIcons.refreshCw),
            label: Text(l10n.networkScanRescan),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.accentInk,
              side: BorderSide(color: AppColors.brandOrange),
              minimumSize: const Size(double.infinity, 48),
            ),
          ),
        ],
      ],
    );
  }
}

class _ProgressRow extends StatelessWidget {
  const _ProgressRow({
    required this.label,
    required this.onStop,
    required this.stopLabel,
  });
  final String label;
  final VoidCallback onStop;
  final String stopLabel;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: AppColors.onSurface,
            ),
          ),
        ),
        TextButton(onPressed: onStop, child: Text(stopLabel)),
      ],
    );
  }
}
