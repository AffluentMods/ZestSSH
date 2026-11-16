import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:uuid/uuid.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/password_managers/agent_listing.dart';
import 'package:zestssh/features/password_managers/agent_sources.dart';
import 'package:zestssh/features/password_managers/password_manager_providers.dart';
import 'package:zestssh/ui/widgets/zest_mode_toggle.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/hardware_token/os_ssh_agent.dart';
import 'package:zestssh/services/hardware_token/ssh_agent_setup.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/ink_layer.dart';

/// Dialog that enumerates the keys currently loaded in the system
/// ssh-agent and lets the user attach one as a ZestSSH identity.
///
/// State machine:
///   * loading       → probing the agent
///   * notInstalled  → "Install OpenSSH" CTA opens settings
///   * stopped       → "Start agent" CTA fires UAC + Start-Service
///   * empty         → agent is up but has no keys → "Add a key…"
///                     CTA file-picks + runs ssh-add
///   * ready         → list of identities + checkboxes + "Add"
///   * error         → free-form detail + Refresh CTA
class HardwareTokenDialog extends ConsumerStatefulWidget {
  const HardwareTokenDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showZestModal<void>(
      context: context,
      size: ZestModalSize.standard,
      child: const HardwareTokenDialog(),
    );
  }

  @override
  ConsumerState<HardwareTokenDialog> createState() =>
      _HardwareTokenDialogState();
}

class _HardwareTokenDialogState extends ConsumerState<HardwareTokenDialog> {
  /// Whose agent the keys come from (3.0): the system's (which
  /// KeePassXC adds its keys to), 1Password's or Bitwarden's.
  AgentSource _source = AgentSource.system;
  AgentSetupReport? _report;
  List<OsAgentIdentity> _identities = const [];
  Set<int> _selectedIndices = {};
  bool _busy = false;
  String? _busyMessage;

  /// What went wrong setting the agent up, shown in this dialog's place (it
  /// was a second dialog over it) until Back; [_agentErrorBack] completes
  /// then.
  String? _agentError;
  Completer<void>? _agentErrorBack;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  String get _sourceName => switch (_source) {
        AgentSource.onePassword => '1Password',
        AgentSource.bitwarden => 'Bitwarden',
        AgentSource.system => '',
      };

  /// What is said where the agent's pipe is served by another account's
  /// program ([AgentPipeNotYours]); [otherwise] for any other failure.
  String _agentFailure(AppLocalizations l10n, Object e, String otherwise) =>
      e is AgentPipeNotYours ? ErrorCodes.withCode(l10n.agentPipeNotYours, ErrorCodes.agentPipeNotYours) : otherwise;

  /// A password manager's agent: listed where this device has it; when it
  /// does not answer, what to turn on in the manager.
  Future<void> _refreshManager() async {
    final l10n = AppLocalizations.of(context)!;
    final source = _source;
    try {
      final list = await listAgentIdentities(agentSocketHere(source.code));
      if (!mounted || source != _source) return;
      setState(() {
        _report = AgentSetupReport(
          state: list.isEmpty ? AgentSetupState.runningEmpty : AgentSetupState.runningWithKeys,
          identityCount: list.length,
        );
        _identities = list;
      });
    } catch (e) {
      if (!mounted || source != _source) return;
      setState(() => _report = AgentSetupReport(
            state: AgentSetupState.unknown,
            detail: _agentFailure(l10n, e, '${l10n.pmAgentUnavailable(_sourceName)}\n\n$e'),
          ));
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _report = null;
      _identities = const [];
      _selectedIndices = {};
    });
    if (_source != AgentSource.system) return _refreshManager();
    final probed = await SshAgentSetupService.probe();
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    final report = probed.pipeNotYours
        ? AgentSetupReport(
            state: AgentSetupState.unknown,
            detail: ErrorCodes.withCode(l10n.agentPipeNotYours, ErrorCodes.agentPipeNotYours),
            pipeNotYours: true,
          )
        : probed;
    if (report.state == AgentSetupState.runningWithKeys ||
        report.state == AgentSetupState.runningEmpty) {
      // Agent is up - pull the identity list explicitly so we can
      // populate the checkbox list with full keyBlob bytes.
      try {
        // Off the main thread: a pipe that hangs cannot freeze the app.
        final list = await listAgentIdentities(null);
        if (!mounted) return;
        setState(() {
          _report = report;
          _identities = list;
        });
        return;
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _report = AgentSetupReport(
            state: AgentSetupState.unknown,
            detail: _agentFailure(l10n, e, e.toString()),
          );
        });
        return;
      }
    }
    setState(() => _report = report);
  }

  Future<void> _runWithBusy(String message, Future<void> Function() task) async {
    setState(() {
      _busy = true;
      _busyMessage = message;
    });
    try {
      await task();
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyMessage = null;
        });
      }
    }
  }

  Future<void> _startAgent() {
    final l10n = AppLocalizations.of(context)!;
    return _runWithBusy(
      l10n.hardwareTokenStartingAgent,
      () async {
        final err = await SshAgentSetupService.startService();
        if (!mounted) return;
        if (err != null) {
          // Errors here are often multi-line (PowerShell exception
          // + script log + suggested causes). A tiny snackbar
          // would lose all of that. Show a real dialog the user
          // can read and copy from.
          await _showAgentErrorDialog(err);
          // After the user dismisses the diagnostic dialog,
          // re-probe so the main dialog reflects the actual
          // current state (e.g. if they fixed it manually in the
          // background).
          if (mounted) await _refresh();
          return;
        }
        showTopSnackBar(context, l10n.hardwareTokenAgentServiceStarted);
        await _refresh();
      },
    );
  }

  /// Says what went wrong in this dialog's place, readable and copied in one
  /// tap, and returns once the person goes Back.
  Future<void> _showAgentErrorDialog(String message) async {
    if (!mounted) return;
    final back = Completer<void>();
    setState(() {
      _agentError = message;
      _agentErrorBack = back;
    });
    await back.future;
  }

  void _leaveAgentError() {
    final back = _agentErrorBack;
    if (mounted) {
      setState(() {
        _agentError = null;
        _agentErrorBack = null;
      });
    }
    if (back != null && !back.isCompleted) back.complete();
  }

  @override
  void dispose() {
    final back = _agentErrorBack;
    if (back != null && !back.isCompleted) back.complete();
    super.dispose();
  }

  Widget _buildAgentError(AppLocalizations l10n, String message) {
    return ZestDialogShell(
      key: const ValueKey('agent-setup-failed'),
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.alertCircle,
      title: l10n.hardwareTokenSetupFailedTitle,
      maxWidth: 580,
      maxHeight: 600,
      onClose: _leaveAgentError,
      body: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.v3Background,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: AppColors.v3BorderSubtle),
        ),
        child: SelectableText(
          message,
          style: TextStyle(
            fontSize: 12,
            height: 1.45,
            color: AppColors.v3TextPrimary,
            fontFamily: 'JetBrainsMono',
          ),
        ),
      ),
      // Copy: the side option; Back to the agent, the main one.
      tertiaryAction: (
        label: l10n.copy,
        onPressed: () {
          Clipboard.setData(ClipboardData(text: message));
          showTopSnackBar(context, l10n.hardwareTokenCopiedDiagnostics);
        },
      ),
      primaryAction: (label: l10n.back, icon: null, onPressed: _leaveAgentError),
      autofocusPrimary: true,
    );
  }

  Future<void> _addKey() {
    final l10n = AppLocalizations.of(context)!;
    return _runWithBusy(
      l10n.hardwareTokenLoadingKey,
      () async {
        final picked = await FilePicker.platform.pickFiles(
          dialogTitle: l10n.hardwareTokenPickKeyDialogTitle,
          type: FileType.any,
          withData: false,
          allowMultiple: false,
        );
        if (picked == null || picked.files.isEmpty) return;
        final path = picked.files.first.path;
        if (path == null) return;
        final err = await SshAgentSetupService.addKey(path);
        if (!mounted) return;
        if (err != null) {
          showTopSnackBar(context, l10n.hardwareTokenSshAddError(err),
              isError: true);
          return;
        }
        showTopSnackBar(context, l10n.hardwareTokenKeyLoaded);
        await _refresh();
      },
    );
  }

  Future<void> _openInstallSettings() {
    final l10n = AppLocalizations.of(context)!;
    return _runWithBusy(
      l10n.hardwareTokenOpeningSettings,
      () async {
        final err = await SshAgentSetupService.openInstallSettings();
        if (!mounted) return;
        if (err != null) {
          showTopSnackBar(context, err, isError: true);
        }
      },
    );
  }

  Future<void> _attach() async {
    if (_selectedIndices.isEmpty) return;
    final l10n = AppLocalizations.of(context)!;
    await _runWithBusy(l10n.hardwareTokenSavingIdentities, () async {
      try {
        final dao = ref.read(identitiesDaoProvider);
        const uuid = Uuid();
        final now = DateTime.now();
        var created = 0;
        for (final idx in _selectedIndices) {
          final agentId = _identities[idx];
          final algo = agentId.algorithm ?? 'ssh-?';
          final id = uuid.v4();
          final label = agentId.comment.isNotEmpty
              ? agentId.comment
              : l10n.hardwareTokenAgentLabel(_friendlyAlgo(algo));

          await dao.insertIdentity(IdentitiesCompanion.insert(
            id: id,
            label: label,
            // The username column requires a non-empty value (min length 1),
            // so an empty string here throws a CHECK-constraint error. Derive a
            // sensible default; the user refines it in the identity editor.
            username: _deriveAgentUsername(agentId.comment),
            authMethod: 'hardwareToken',
            keyType: Value(_keyTypeFromAlgo(algo)),
            publicKeyData: Value(_toOpenSshPubLine(agentId)),
            publicKeyFingerprint: const Value(null),
            usesAgent: const Value(true),
            agentSource: Value(_source == AgentSource.system ? null : _source.code),
            createdAt: now,
          ));
          created += 1;
        }
        ref.invalidate(identitiesProvider);
        if (!mounted) return;
        Navigator.of(context).pop();
        showTopSnackBar(
          context,
          l10n.hardwareTokenAddedIdentities(created),
        );
      } catch (e) {
        // Never swallow the failure - surface it so "nothing happens" can't
        // recur (previously a DB error here left the dialog silently stuck).
        if (!mounted) return;
        showTopSnackBar(context, l10n.hardwareTokenNotAdded, isError: true, details: '$e');
      }
    });
  }

  /// A non-empty username for an agent identity (the column requires min
  /// length 1). Agent comments are usually `user@host` → take the user part;
  /// else the current OS user; else a generic placeholder. Clamped to the
  /// column's 255-char max.
  String _deriveAgentUsername(String comment) {
    final at = comment.indexOf('@');
    String u;
    if (at > 0) {
      u = comment.substring(0, at);
    } else {
      final env = Platform.environment['USER'] ??
          Platform.environment['USERNAME'] ??
          '';
      u = env.trim().isNotEmpty ? env.trim() : 'agent';
    }
    return u.length > 255 ? u.substring(0, 255) : u;
  }

  /// True for FIDO2 / hardware-resident algorithms (`sk-*`). Drives
  /// the badge: hardware-resident keys mean "private key never
  /// leaves the device - physical touch required per signature".
  /// Software keys live in agent memory; no touch needed.
  bool _isHardwareAlgo(String wireName) {
    return wireName.startsWith('sk-');
  }

  String _friendlyAlgo(String wireName) {
    switch (wireName) {
      case 'ssh-ed25519':
        return 'Ed25519';
      case 'ssh-rsa':
        return 'RSA';
      case 'ecdsa-sha2-nistp256':
        return 'ECDSA P-256';
      case 'ecdsa-sha2-nistp384':
        return 'ECDSA P-384';
      case 'ecdsa-sha2-nistp521':
        return 'ECDSA P-521';
      case 'sk-ssh-ed25519@openssh.com':
        return 'Ed25519 (FIDO2)';
      case 'sk-ecdsa-sha2-nistp256@openssh.com':
        return 'ECDSA P-256 (FIDO2)';
      default:
        return wireName;
    }
  }

  String _keyTypeFromAlgo(String wireName) {
    switch (wireName) {
      case 'ssh-ed25519':
        return 'ed25519';
      case 'ssh-rsa':
        return 'rsa';
      case 'ecdsa-sha2-nistp256':
        return 'ecdsaP256';
      case 'ecdsa-sha2-nistp384':
        return 'ecdsaP384';
      case 'ecdsa-sha2-nistp521':
        return 'ecdsaP521';
      case 'sk-ssh-ed25519@openssh.com':
        return 'skEd25519';
      case 'sk-ecdsa-sha2-nistp256@openssh.com':
        return 'skEcdsaP256';
      default:
        return wireName;
    }
  }

  String _toOpenSshPubLine(OsAgentIdentity i) {
    final algo = i.algorithm ?? 'unknown';
    final b64 = _b64.encode(i.publicKeyBlob);
    final c = i.comment.isEmpty ? '' : ' ${i.comment}';
    return '$algo $b64$c';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final agentError = _agentError;
    if (agentError != null) return _buildAgentError(l10n, agentError);
    final hasReadyKeys = _report?.state == AgentSetupState.runningWithKeys;
    final canAttach = hasReadyKeys && _selectedIndices.isNotEmpty && !_busy;
    // Watched so the key list re-masks live when recording mode (or its
    // level) toggles; the row builder runs outside this build and uses
    // `.display`.
    ref.watch(recordingModeProvider);
    ref.watch(recordingRedactLevelProvider);

    return ZestDialogShell(
      tone: ZestDialogTone.info,
      icon: LucideIcons.usb,
      title: l10n.hardwareTokenTitle,
      subtitle: l10n.hardwareTokenSubtitle,
      maxWidth: 580,
      maxHeight: 600,
      tertiaryAction: (
        label: l10n.hardwareTokenRefresh,
        onPressed: _busy ? null : _refresh,
      ),
      secondaryAction: (
        label: l10n.cancel,
        onPressed: _busy ? null : () => Navigator.of(context).pop(),
      ),
      primaryAction: hasReadyKeys
          ? (
              label: _busy
                  ? l10n.hardwareTokenSaving
                  : (_selectedIndices.length <= 1
                      ? l10n.hardwareTokenAddIdentity
                      : l10n.hardwareTokenAddIdentitiesCount(
                          _selectedIndices.length)),
              icon: _busy ? null : LucideIcons.check,
              onPressed: canAttach ? _attach : null,
            )
          : null,
      body: SizedBox(
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: ZestModeToggle(
                key: const ValueKey('agent-source'),
                selectedId: _source.code,
                onChanged: (id) {
                  if (_busy || id == _source.code) return;
                  setState(() => _source = AgentSource.of(id));
                  _refresh();
                },
                segments: [
                  ZestModeSegment(id: AgentSource.system.code, label: l10n.pmAgentSourceSystem),
                  ZestModeSegment(id: AgentSource.onePassword.code, label: '1Password'),
                  ZestModeSegment(id: AgentSource.bitwarden.code, label: 'Bitwarden'),
                ],
              ),
            ),
            if (_source != AgentSource.system && Platform.isWindows) ...[
              const SizedBox(height: 8),
              Text(l10n.pmAgentWindowsNote(_sourceName),
                  key: const ValueKey('agent-windows-note'),
                  style: TextStyle(color: AppColors.onSurfaceVariant, fontSize: 12, height: 1.4)),
            ],
            const SizedBox(height: 12),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_busy && _busyMessage != null) {
      return _buildLoading(_busyMessage!);
    }
    final l10n = AppLocalizations.of(context)!;
    final report = _report;
    if (report == null) return _buildLoading(l10n.hardwareTokenProbing);
    switch (report.state) {
      case AgentSetupState.runningWithKeys:
        return _buildKeyList();
      case AgentSetupState.runningEmpty:
        // A password manager's keys are added in the manager, not here.
        if (_source != AgentSource.system) {
          return Center(
            child: Text(l10n.pmAgentEmpty(_sourceName),
                key: const ValueKey('agent-manager-empty'),
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.onSurfaceVariant, fontSize: 13, height: 1.45)),
          );
        }
        return _buildEmptyAgent();
      case AgentSetupState.installedStopped:
        return _buildStopped();
      case AgentSetupState.notInstalled:
        return _buildNotInstalled();
      case AgentSetupState.unknown:
        return _buildUnknownError(report.detail);
    }
  }

  Widget _buildLoading(String label) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(label,
              style: TextStyle(
                  color: AppColors.onSurfaceVariant, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _buildKeyList() {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.hardwareTokenKeyListHeader(_identities.length),
          style: TextStyle(
              color: AppColors.onSurfaceVariant, fontSize: 12, height: 1.4),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppColors.divider, width: 0.5),
            ),
            child: InkLayer(
              child: ListView.builder(
              itemCount: _identities.length,
              itemBuilder: (_, i) {
                final id = _identities[i];
                final selected = _selectedIndices.contains(i);
                final algo = id.algorithm ?? 'unknown';
                final isHardware = _isHardwareAlgo(algo);
                // The public-key prefix identifies the key the way a
                // fingerprint does; the algorithm name does not.
                final pubPrefix =
                    Redactable.fingerprint(_shortHex(id.publicKeyBlob)).display;
                return CheckboxListTile(
                  value: selected,
                  onChanged: (v) {
                    setState(() {
                      if (v == true) {
                        _selectedIndices = {..._selectedIndices, i};
                      } else {
                        _selectedIndices = {..._selectedIndices}..remove(i);
                      }
                    });
                  },
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Row(
                    children: [
                      // The agent key's comment (usually `user@host`) is an
                      // identifier: key-comment rule while recording.
                      Flexible(
                        child: id.comment.isEmpty
                            ? Text(
                                l10n.hardwareTokenNoComment,
                                style: TextStyle(
                                    fontSize: 13, color: AppColors.onSurface),
                                overflow: TextOverflow.ellipsis,
                              )
                            : RedactedText(
                                Redactable.keyComment(id.comment),
                                style: TextStyle(
                                    fontSize: 13, color: AppColors.onSurface),
                                overflow: TextOverflow.ellipsis,
                              ),
                      ),
                      const SizedBox(width: 8),
                      _KeyKindBadge(isHardware: isHardware),
                    ],
                  ),
                  subtitle: Text(
                    l10n.hardwareTokenKeySubtitle(
                        _friendlyAlgo(algo), pubPrefix),
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.onSurfaceVariant,
                      fontFamily: 'JetBrainsMono',
                    ),
                  ),
                );
              },
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: _busy ? null : _addKey,
          icon: const Icon(LucideIcons.plus, size: 16),
          label: Text(l10n.hardwareTokenAddAnotherKey),
        ),
      ],
    );
  }

  Widget _buildEmptyAgent() {
    final l10n = AppLocalizations.of(context)!;
    return _CenteredEmptyState(
      icon: LucideIcons.keyRound,
      title: l10n.hardwareTokenEmptyTitle,
      description: l10n.hardwareTokenEmptyDescription,
      primaryLabel: l10n.hardwareTokenAddAKey,
      primaryIcon: LucideIcons.plus,
      onPrimary: _addKey,
    );
  }

  Widget _buildStopped() {
    final l10n = AppLocalizations.of(context)!;
    final isWindows = Platform.isWindows;
    return _CenteredEmptyState(
      icon: LucideIcons.power,
      title: l10n.hardwareTokenStoppedTitle,
      description: isWindows
          ? l10n.hardwareTokenStoppedDescWindows
          : l10n.hardwareTokenStoppedDescUnix,
      primaryLabel: isWindows ? l10n.hardwareTokenStartAgent : null,
      primaryIcon: LucideIcons.play,
      onPrimary: isWindows ? _startAgent : null,
    );
  }

  Widget _buildNotInstalled() {
    final l10n = AppLocalizations.of(context)!;
    final isWindows = Platform.isWindows;
    return _CenteredEmptyState(
      icon: LucideIcons.download,
      title: l10n.hardwareTokenNotInstalledTitle,
      description: isWindows
          ? l10n.hardwareTokenNotInstalledDescWindows
          : l10n.hardwareTokenNotInstalledDescUnix,
      primaryLabel: isWindows ? l10n.hardwareTokenOpenSettings : null,
      primaryIcon: LucideIcons.settings,
      onPrimary: isWindows ? _openInstallSettings : null,
    );
  }

  Widget _buildUnknownError(String? detail) {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.alertCircle,
                size: 36, color: AppColors.error),
            const SizedBox(height: 12),
            Text(
              l10n.hardwareTokenUnknownErrorTitle,
              style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: AppColors.onSurface),
            ),
            const SizedBox(height: 8),
            Text(
              detail ?? l10n.hardwareTokenNoDetail,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 12, color: AppColors.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _busy ? null : _refresh,
              icon: const Icon(LucideIcons.refreshCw, size: 16),
              label: Text(l10n.retry),
            ),
          ],
        ),
      ),
    );
  }

  String _shortHex(List<int> bytes) {
    if (bytes.length < 16) {
      return bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
    }
    final hex = bytes
        .take(16)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return '$hex…';
  }
}

/// Pill badge that distinguishes hardware-token-resident keys from
/// software keys held in agent memory. The label is the most useful
/// detail per row - algorithm names alone (sk-ssh-ed25519@... vs
/// ssh-ed25519) are obscure for non-experts.
class _KeyKindBadge extends StatelessWidget {
  const _KeyKindBadge({required this.isHardware});
  final bool isHardware;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final color = isHardware ? AppColors.accentInk : AppColors.cloudSync;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
            color: color.withValues(alpha: 0.40), width: 0.6),
      ),
      child: Text(
        isHardware ? l10n.hardwareTokenBadgeHardware : l10n.hardwareTokenBadgeSoftware,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: color,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

/// Centered "empty state" with optional CTA button. Used for all the
/// non-key-list states (stopped, not installed, agent empty).
class _CenteredEmptyState extends StatelessWidget {
  const _CenteredEmptyState({
    required this.icon,
    required this.title,
    required this.description,
    this.primaryLabel,
    this.primaryIcon,
    this.onPrimary,
  });

  final IconData icon;
  final String title;
  final String description;
  final String? primaryLabel;
  final IconData? primaryIcon;
  final VoidCallback? onPrimary;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: AppColors.onSurfaceDim),
            const SizedBox(height: 16),
            Text(
              title,
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.onSurface),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              description,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: AppColors.onSurfaceVariant,
                height: 1.45,
              ),
            ),
            if (primaryLabel != null) ...[
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: onPrimary,
                icon: Icon(primaryIcon ?? LucideIcons.arrowRight, size: 16),
                label: Text(primaryLabel!),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.brandOrange,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 18, vertical: 12),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Tiny inline base64 codec - same as os_logos uses elsewhere; keeping
/// it local so we don't drag dart:convert into a UI file.
const _b64 = _Base64Codec();

class _Base64Codec {
  const _Base64Codec();
  static const String _alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

  String encode(List<int> bytes) {
    final out = StringBuffer();
    var i = 0;
    while (i + 3 <= bytes.length) {
      final n = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
      out.write(_alphabet[(n >> 18) & 63]);
      out.write(_alphabet[(n >> 12) & 63]);
      out.write(_alphabet[(n >> 6) & 63]);
      out.write(_alphabet[n & 63]);
      i += 3;
    }
    final rem = bytes.length - i;
    if (rem == 1) {
      final n = bytes[i] << 16;
      out.write(_alphabet[(n >> 18) & 63]);
      out.write(_alphabet[(n >> 12) & 63]);
      out.write('==');
    } else if (rem == 2) {
      final n = (bytes[i] << 16) | (bytes[i + 1] << 8);
      out.write(_alphabet[(n >> 18) & 63]);
      out.write(_alphabet[(n >> 12) & 63]);
      out.write(_alphabet[(n >> 6) & 63]);
      out.write('=');
    }
    return out.toString();
  }
}
