import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/theme/ui_density.dart' show touchSizedAt;
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/features/hosts/host_tester.dart';
import 'package:zestssh/features/hosts/widgets/host_network_overrides_section.dart' show EffectiveTestConfig;
import 'package:zestssh/features/orchards/guardrails.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';

/// What a connection test found, in place: the verdict, what it said (masked
/// in recording mode: a socket or SSH error often names the address or the
/// user), the report behind "Copy details", and a way to dismiss it.
class HostTestResultBanner extends StatelessWidget {
  const HostTestResultBanner({super.key, required this.result, required this.onClose});

  final HostTestResult result;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: result.success
            ? AppColors.success.withValues(alpha: 0.1)
            : AppColors.error.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: result.success ? AppColors.success : AppColors.error,
          width: 0.5,
        ),
      ),
      child: Row(
        children: [
          Icon(
            result.success ? LucideIcons.checkCircle2 : LucideIcons.alertCircle,
            color: result.success ? AppColors.success : AppColors.error,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  result.success ? l10n.connectionSuccessful : l10n.connectionFailed,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: result.success ? AppColors.success : AppColors.error,
                  ),
                ),
                // A socket / SSH error often names the address or the
                // user; the free-text rule masks those in recording mode.
                if (result.message.isNotEmpty)
                  RedactedText(
                    Redactable.freeText(result.message),
                    style: TextStyle(
                      fontSize: 12,
                      color: result.success ? AppColors.success : AppColors.error,
                    ),
                  ),
                // Raw SSH/socket text tucked behind a copy button; the
                // message above stays a plain description.
                if (!result.success && result.detail != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: CopyDetailsButton(
                      detail: result.detail!,
                      color: AppColors.error,
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: l10n.close,
            icon: const Icon(LucideIcons.x, size: 16),
            onPressed: onClose,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }
}

/// Whether a host of [protocol] has the two tests: what the editor's footer
/// offers them for. A local shell and Telnet have nothing to sign in to here.
bool hostProtocolCanBeTested(String protocol) => const {
      'ssh',
      'sftp',
      'mosh',
      'et',
      'serial',
    }.contains(protocol.toLowerCase());

/// The host panel's two tests: Test reachability
/// and Test full connection on the host as it is saved, what they find under
/// them. They run through the same [HostTester] as the editor's, with every
/// gate it has.
class HostPanelTests extends ConsumerStatefulWidget {
  const HostPanelTests({super.key, required this.item});

  final ConnectionWithDetails item;

  @override
  ConsumerState<HostPanelTests> createState() => _HostPanelTestsState();
}

class _HostPanelTestsState extends ConsumerState<HostPanelTests> {
  /// Which is running: nothing while null.
  _Test? _running;
  HostTestResult? _result;

  EffectiveTestConfig get _config {
    final conn = widget.item.connection;
    final via = conn.connectViaId;
    return EffectiveTestConfig(
      host: conn.host,
      port: conn.port,
      identityKeyId: conn.identityId,
      jumpChain: via == null ? const <String>[] : <String>[via],
    );
  }

  HostTester get _tester {
    final conn = widget.item.connection;
    return HostTester(
      context: context,
      ref: ref,
      hostId: conn.id,
      compatibilityMode: conn.compatibilityMode,
      sftpOnly: conn.protocol.toLowerCase() == ConnectionProtocol.sftp.name,
      addressTypedHere: false,
      // The address is the saved host's: chosen here only by an account that
      // may change it (3.0, as the editor has it).
      addressChosenHere: (_) async => mayChangeItem(ref, 'host', conn.id, watch: false),
    );
  }

  Future<void> _run(_Test test) async {
    void started() => setState(() {
          _running = test;
          _result = null;
        });
    try {
      final result = await switch (test) {
        _Test.reachability => _tester.reachability(_config, onStarted: started),
        _Test.full => _tester.fullConnection(_config, onStarted: started),
      };
      if (mounted && result != null) setState(() => _result = result);
    } finally {
      if (mounted) setState(() => _running = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final result = _result;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        if (touchSizedAt(context))
          // Touch sized (4.0, a tablet in landscape): each test a
          // full row 48 high, in one card.
          _TestRows(
            running: _running,
            onRun: _run,
            reachability: l10n.zestHostTestReachability,
            full: l10n.zestHostTestFull,
          )
        else
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            ZestButton(
              key: const ValueKey('host-panel-test-reachability'),
              label: l10n.zestHostTestReachability,
              icon: LucideIcons.radio,
              isLoading: _running == _Test.reachability,
              onPressed: _running != null ? null : () => _run(_Test.reachability),
            ),
            ZestButton(
              key: const ValueKey('host-panel-test-full'),
              label: l10n.zestHostTestFull,
              icon: LucideIcons.lock,
              isLoading: _running == _Test.full,
              onPressed: _running != null ? null : () => _run(_Test.full),
            ),
          ],
        ),
        if (result != null) ...[
          const SizedBox(height: 8),
          HostTestResultBanner(
            key: const ValueKey('host-panel-test-result'),
            result: result,
            onClose: () => setState(() => _result = null),
          ),
        ],
      ],
    );
  }
}

enum _Test { reachability, full }

/// The host panel's two tests as rows of a card, each the card's width and a
/// finger's 48 high, a spinner in place of its icon while it runs.
class _TestRows extends StatelessWidget {
  const _TestRows({required this.running, required this.onRun, required this.reachability, required this.full});

  final _Test? running;
  final void Function(_Test test) onRun;
  final String reachability;
  final String full;

  @override
  Widget build(BuildContext context) {
    Widget row(_Test test, IconData icon, String label, String key) {
      final busy = running == test;
      return Semantics(
        button: true,
        enabled: running == null,
        child: InkWell(
          key: ValueKey(key),
          onTap: running != null ? null : () => onRun(test),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: busy
                        ? const CircularProgressIndicator(strokeWidth: 2)
                        : Icon(icon, size: 16, color: ZestColors.textSecondary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 14,
                        color: running != null && !busy ? ZestColors.textDisabled : ZestColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: ZestColors.borderDefault),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          row(_Test.reachability, LucideIcons.activity, reachability, 'host-panel-test-reachability'),
          Divider(height: 1, color: ZestColors.borderDefault),
          row(_Test.full, LucideIcons.lock, full, 'host-panel-test-full'),
        ],
      ),
    );
  }
}
