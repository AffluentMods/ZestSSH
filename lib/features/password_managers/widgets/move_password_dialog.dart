import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/password_managers/password_manager_cli.dart';
import 'package:zestssh/features/password_managers/password_manager_providers.dart';
import 'package:zestssh/features/password_managers/password_manager_ref.dart';
import 'package:zestssh/features/password_managers/password_managers.dart';
import 'package:zestssh/features/password_managers/widgets/password_manager_dialogs.dart';
import 'package:zestssh/features/password_managers/widgets/password_manager_tool_setup.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_mode_toggle.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';

// Moving a saved password out of ZestSSH into the person's password manager
// (3.0): a new item there, the key then fetches it from it, and
// ZestSSH deletes its own copy. For keys in the person's own Tree only: a
// team's password copied into someone's own vault would be an export.

/// Moves the saved password of [identity]; the key as it is now, or null
/// when nothing moved.
Future<Identity?> showMovePasswordToManager(BuildContext context, WidgetRef ref, Identity identity) async {
  final l10n = AppLocalizations.of(context)!;
  final managers = ref.read(passwordManagersProvider);
  if (managers == null) return null;
  final crud = ref.read(identityCrudProvider);
  final password = await crud.getPassword(identity.id);
  if (!context.mounted) return null;
  if (password == null || password.isEmpty) {
    showTopSnackBar(context, l10n.pmMoveNothing, isError: true);
    return null;
  }
  final moved = await ZestDialogShell.showModal<PasswordRef>(
    context,
    size: ZestModalSize.standard,
    tone: ZestDialogTone.info,
    icon: LucideIcons.arrowRightLeft,
    title: l10n.pmMoveTitle,
    body: _MovePassword(managers: managers, identity: identity, password: password),
  );
  if (moved == null) return null;
  await crud.update(id: identity.id, authMethod: 'passwordManager', passwordRef: moved.encode());
  await crud.clearSecrets(identity.id);
  return ref.read(identitiesDaoProvider).getById(identity.id);
}

class _MovePassword extends StatefulWidget {
  const _MovePassword({required this.managers, required this.identity, required this.password});

  final PasswordManagers managers;
  final Identity identity;
  final String password;

  @override
  State<_MovePassword> createState() => _MovePasswordState();
}

class _MovePasswordState extends State<_MovePassword> {
  var _kind = PasswordManagerKind.onePassword;
  late final _entry = TextEditingController(text: 'ZestSSH/${widget.identity.label}');
  Future<List<({String id, String name})>>? _vaults;
  String? _vault;
  PasswordManagerException? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadVaults();
  }

  @override
  void dispose() {
    _entry.dispose();
    super.dispose();
  }

  void _loadVaults() {
    if (_kind != PasswordManagerKind.onePassword || widget.managers.toolPath(_kind) == null) return;
    _vaults = widget.managers.onePasswordVaults().then((v) {
      if (mounted && _vault == null && v.isNotEmpty) setState(() => _vault = v.first.id);
      return v;
    });
  }

  Future<void> _move() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ref = await widget.managers.store(
        _kind,
        title: widget.identity.label,
        username: widget.identity.username,
        password: widget.password,
        vaultId: _vault,
        entryPath: _entry.text.trim(),
        ask: (kind, {required again}) => showPasswordManagerUnlock(context, kind, again: again),
      );
      if (mounted) Navigator.of(context, rootNavigator: true).pop(ref);
    } on PasswordManagerException catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final name = passwordManagerName(_kind);
    final tool = widget.managers.toolPath(_kind);
    final error = _error;
    final ready = tool != null &&
        !_busy &&
        switch (_kind) {
          PasswordManagerKind.onePassword => _vault != null,
          PasswordManagerKind.bitwarden => true,
          PasswordManagerKind.keePassXc => PasswordRef.keePassXc(_entry.text) != null,
        };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(l10n.pmMoveBody(name), style: TextStyle(fontSize: 12.5, height: 1.4, color: AppColors.v3TextSecondary)),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: ZestModeToggle(
            key: const ValueKey('pm-move-kind'),
            selectedId: _kind.code,
            onChanged: (id) {
              final kind = PasswordManagerKind.fromCode(id);
              if (kind == null || kind == _kind || _busy) return;
              setState(() {
                _kind = kind;
                _error = null;
                _loadVaults();
              });
            },
            segments: [
              for (final k in PasswordManagerKind.values) ZestModeSegment(id: k.code, label: passwordManagerName(k)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (tool == null)
          // Not there: set up right here (it pointed to Settings).
          PasswordManagerToolSetup(
              key: ValueKey('pm-setup-in-move-${_kind.code}'),
              kind: _kind,
              onChanged: () => setState(_loadVaults))
        else if (_kind == PasswordManagerKind.onePassword)
          FutureBuilder<List<({String id, String name})>>(
            future: _vaults,
            builder: (context, snap) {
              if (snap.hasError) {
                final e = snap.error;
                return Text(
                    e is PasswordManagerException
                        ? passwordManagerFailureText(l10n, _kind, e.failure)
                        : l10n.pmFailFailed(passwordManagerTool(_kind)),
                    key: const ValueKey('pm-move-vault-error'),
                    style: TextStyle(fontSize: 12.5, color: AppColors.v3Warning));
              }
              final vaults = snap.data;
              if (vaults == null) {
                return const Align(
                  alignment: Alignment.centerLeft,
                  child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 1.8)),
                );
              }
              // Its name over the app's select (a Material dropdown with a
              // floating label).
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  ZestFieldLabel(l10n.pmMoveVault),
                  const SizedBox(height: 6),
                  ZestSelect<String>(
                    key: const ValueKey('pm-move-vault'),
                    value: _vault,
                    items: [for (final v in vaults) ZestSelectItem(v.id, v.name)],
                    onChanged: _busy ? null : (v) => setState(() => _vault = v),
                  ),
                ],
              );
            },
          )
        else if (_kind == PasswordManagerKind.keePassXc)
          TextField(
            key: const ValueKey('pm-move-entry'),
            controller: _entry,
            decoration: InputDecoration(labelText: l10n.pmMoveEntry, isDense: true, border: const OutlineInputBorder()),
            onChanged: (_) => setState(() {}),
          ),
        if (error != null) ...[
          const SizedBox(height: 10),
          Text(passwordManagerFailureText(l10n, _kind, error.failure),
              key: const ValueKey('pm-move-error'), style: TextStyle(fontSize: 12.5, color: AppColors.v3Warning)),
          if (error.details case final details?) ...[
            const SizedBox(height: 8),
            PasswordManagerDetails(details: details),
          ],
        ],
        const SizedBox(height: 14),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            key: const ValueKey('pm-move-go'),
            onPressed: ready ? () => unawaited(_move()) : null,
            icon: _busy
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.6))
                : const Icon(LucideIcons.arrowRightLeft, size: 15),
            label: Text(l10n.pmMove),
          ),
        ),
      ],
    );
  }
}
