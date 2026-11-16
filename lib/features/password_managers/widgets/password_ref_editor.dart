import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/password_managers/password_manager_cli.dart';
import 'package:zestssh/features/password_managers/password_manager_import.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/password_managers/password_manager_providers.dart';
import 'package:zestssh/features/password_managers/password_manager_ref.dart';
import 'package:zestssh/features/password_managers/password_managers.dart';
import 'package:zestssh/features/password_managers/widgets/password_manager_dialogs.dart';
import 'package:zestssh/features/password_managers/widgets/password_manager_tool_setup.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_field.dart';
import 'package:zestssh/ui/widgets/zest_mode_toggle.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/host_address.dart';

// Where a key's password lives in the person's password manager (3.0),
// in the key editors: the manager, and the item picked from it (or its
// reference typed in). Only the reference is kept; the password never is.

/// The reference editor. [value] is the stored reference (or null);
/// [onChanged] gets the stored form of a valid reference, or null while the
/// field does not hold one.
class PasswordRefEditor extends ConsumerStatefulWidget {
  const PasswordRefEditor({super.key, required this.value, required this.onChanged, this.labelWidth});

  final String? value;
  final ValueChanged<String?> onChanged;
  final double? labelWidth;

  @override
  ConsumerState<PasswordRefEditor> createState() => _PasswordRefEditorState();
}

class _PasswordRefEditorState extends ConsumerState<PasswordRefEditor> {
  late PasswordManagerKind _kind;
  final _target = TextEditingController();
  final _attribute = TextEditingController();
  PasswordManagerItem? _picked;

  @override
  void initState() {
    super.initState();
    final ref = PasswordRef.decode(widget.value);
    _kind = ref?.kind ?? PasswordManagerKind.onePassword;
    _target.text = ref?.target ?? '';
    _attribute.text = ref?.field ?? '';
  }

  @override
  void dispose() {
    _target.dispose();
    _attribute.dispose();
    super.dispose();
  }

  PasswordRef? get _ref => switch (_kind) {
        PasswordManagerKind.onePassword => PasswordRef.onePassword(_target.text),
        PasswordManagerKind.bitwarden => PasswordRef.bitwarden(_target.text),
        PasswordManagerKind.keePassXc => PasswordRef.keePassXc(_target.text,
            attribute: _attribute.text.trim().isEmpty ? 'Password' : _attribute.text),
      };

  void _changed() {
    setState(() {});
    widget.onChanged(_ref?.encode());
  }

  Future<void> _pick(PasswordManagers managers) async {
    final item = await showPasswordManagerPicker(context, managers, _kind);
    if (item == null || !mounted) return;
    _target.text = item.ref.target;
    _attribute.text = item.ref.field ?? '';
    _picked = item;
    _changed();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final managers = ref.watch(passwordManagersProvider);
    // The tool's place, looked up when the settings change.
    ref.watch(passwordManagerSettingsProvider);
    final name = passwordManagerName(_kind);
    final tool = managers?.toolPath(_kind);
    final invalid = _target.text.trim().isNotEmpty && _ref == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: ZestModeToggle(
            key: const ValueKey('pm-kind'),
            selectedId: _kind.code,
            onChanged: (id) {
              final kind = PasswordManagerKind.fromCode(id);
              if (kind == null || kind == _kind) return;
              _kind = kind;
              _target.clear();
              _attribute.clear();
              _picked = null;
              _changed();
            },
            segments: [
              for (final k in PasswordManagerKind.values) ZestModeSegment(id: k.code, label: passwordManagerName(k)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        ZestField(
          key: const ValueKey('pm-ref-field'),
          label: switch (_kind) {
            PasswordManagerKind.onePassword => l10n.pmRefOnePasswordLabel,
            PasswordManagerKind.bitwarden => l10n.pmRefBitwardenLabel,
            PasswordManagerKind.keePassXc => l10n.pmRefKeePassXcLabel,
          },
          controller: _target,
          placeholder: switch (_kind) {
            PasswordManagerKind.onePassword => 'op://Vault/Item/password',
            PasswordManagerKind.bitwarden => '00000000-0000-0000-0000-000000000000',
            PasswordManagerKind.keePassXc => 'Servers/web1',
          },
          isMono: true,
          labelWidth: widget.labelWidth,
          errorText: invalid ? l10n.pmRefInvalid : null,
          onChanged: (_) {
            _picked = null;
            _changed();
          },
        ),
        if (_kind == PasswordManagerKind.keePassXc) ...[
          const SizedBox(height: 10),
          ZestField(
            key: const ValueKey('pm-attribute-field'),
            label: l10n.pmRefKeePassXcAttribute,
            controller: _attribute,
            placeholder: 'Password',
            labelWidth: widget.labelWidth,
            onChanged: (_) => _changed(),
          ),
        ],
        if (_picked case final picked?) ...[
          const SizedBox(height: 6),
          Text(
            [picked.title, ?picked.where, ?picked.username].join(' · '),
            key: const ValueKey('pm-picked'),
            style: TextStyle(fontSize: 12, color: AppColors.v3TextSecondary),
          ),
        ],
        const SizedBox(height: 10),
        if (managers != null) ...[
          // Where the tool is, or setting it up right here (it pointed to
          // Settings); the item is chosen once it is there.
          PasswordManagerToolSetup(
              key: ValueKey('pm-setup-in-editor-${_kind.code}'), kind: _kind, onChanged: () => setState(() {})),
          if (tool != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const ValueKey('pm-choose'),
                onPressed: () => unawaited(_pick(managers)),
                icon: const Icon(LucideIcons.listChecks, size: 14),
                label: Text(l10n.pmChooseFrom(name)),
              ),
            ),
          ],
        ],
        const SizedBox(height: 8),
        Text(
          managers == null ? l10n.pmRefNotePhone(name) : l10n.pmRefNote(name),
          key: const ValueKey('pm-note'),
          style: TextStyle(fontSize: 12, height: 1.4, color: AppColors.v3TextSecondary),
        ),
      ],
    );
  }
}

/// The items of [kind] to pick one from; null when none was picked.
Future<PasswordManagerItem?> showPasswordManagerPicker(
    BuildContext context, PasswordManagers managers, PasswordManagerKind kind) {
  final l10n = AppLocalizations.of(context)!;
  return ZestDialogShell.showModal<PasswordManagerItem>(
    context,
    size: ZestModalSize.standard,
    tone: ZestDialogTone.info,
    icon: LucideIcons.listChecks,
    title: l10n.pmChooseFrom(passwordManagerName(kind)),
    body: _Picker(managers: managers, kind: kind),
    secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context, rootNavigator: true).pop()),
  );
}

class _Picker extends StatefulWidget {
  const _Picker({super.key, required this.managers, required this.kind, this.selection});

  final PasswordManagers managers;
  final PasswordManagerKind kind;

  /// Picking several (adding from a password manager): the items ticked.
  /// Null: one, picked with a tap.
  final ValueNotifier<List<PasswordManagerItem>>? selection;

  @override
  State<_Picker> createState() => _PickerState();
}

class _PickerState extends State<_Picker> {
  final _search = TextEditingController();
  List<PasswordManagerItem>? _items;
  PasswordManagerException? _error;
  bool _loading = false;

  /// Bitwarden lists only what matches a search, asked for on Enter.
  bool get _searchFirst => widget.kind == PasswordManagerKind.bitwarden;

  @override
  void initState() {
    super.initState();
    if (!_searchFirst) unawaited(_load());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await widget.managers.listItems(widget.kind,
          search: _searchFirst ? _search.text : '',
          ask: (kind, {required again}) => showPasswordManagerUnlock(context, kind, again: again));
      if (mounted) setState(() => _items = items);
    } on PasswordManagerException catch (e) {
      AppLogger.info('Password managers: items not listed (${e.failure.name})');
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final query = _search.text.trim().toLowerCase();
    final items = [
      for (final i in _items ?? const <PasswordManagerItem>[])
        if (_searchFirst ||
            query.isEmpty ||
            i.title.toLowerCase().contains(query) ||
            (i.where?.toLowerCase().contains(query) ?? false) ||
            (i.username?.toLowerCase().contains(query) ?? false))
          i,
    ];
    final error = _error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          key: const ValueKey('pm-pick-search'),
          controller: _search,
          autofocus: true,
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(LucideIcons.search, size: 16),
            hintText: _searchFirst ? l10n.pmPickSearchBitwarden : l10n.pmPickSearch,
            border: const OutlineInputBorder(),
          ),
          onChanged: _searchFirst ? null : (_) => setState(() {}),
          onSubmitted: _searchFirst ? (_) => unawaited(_load()) : null,
        ),
        const SizedBox(height: 10),
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 1.8))),
          )
        else if (error != null) ...[
          Text(passwordManagerFailureText(l10n, widget.kind, error.failure),
              key: const ValueKey('pm-pick-error'), style: TextStyle(fontSize: 12.5, color: AppColors.v3Warning)),
          if (error.details case final details?) ...[
            const SizedBox(height: 8),
            PasswordManagerDetails(details: details),
          ],
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(onPressed: () => unawaited(_load()), child: Text(l10n.pmPickRetry)),
          ),
        ] else if (_items != null && items.isEmpty)
          Text(l10n.pmPickEmpty, key: const ValueKey('pm-pick-empty'), style: TextStyle(color: AppColors.v3TextSecondary))
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final i in items)
                  if (widget.selection case final selection?)
                    CheckboxListTile(
                      key: ValueKey('pm-pick-${i.ref.target}'),
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: selection.value.contains(i),
                      title: Text(i.title),
                      subtitle: Text(
                        [
                          ?i.where,
                          ?i.username,
                          if (sshTargetOf(i.url) case final t?) l10n.pmAddMakesHost(hostWithPort(t.host, t.port)),
                        ].join(' · '),
                        style: const TextStyle(fontSize: 11.5),
                      ),
                      onChanged: (on) => setState(() => selection.value = [
                            for (final s in selection.value)
                              if (s != i) s,
                            if (on == true) i,
                          ]),
                    )
                  else
                    ListTile(
                      key: ValueKey('pm-pick-${i.ref.target}'),
                      dense: true,
                      leading: const Icon(LucideIcons.keyRound, size: 16),
                      title: Text(i.title),
                      subtitle: i.where == null && i.username == null
                          ? null
                          : Text([?i.where, ?i.username].join(' · '), style: const TextStyle(fontSize: 11.5)),
                      onTap: () => Navigator.of(context, rootNavigator: true).pop(i),
                    ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Adds keys (and hosts) from the person's password manager: several
/// items picked, each a key keeping only its reference, and a host for each
/// whose address is an SSH one. What was added, or null when nothing was.
Future<PasswordManagerImport?> showAddFromPasswordManager(BuildContext context, WidgetRef ref) async {
  final managers = ref.read(passwordManagersProvider);
  if (managers == null) return null;
  final picked = await ZestDialogShell.showModal<(PasswordManagerKind, List<PasswordManagerItem>)>(
    context,
    size: ZestModalSize.large,
    tone: ZestDialogTone.info,
    icon: LucideIcons.listChecks,
    title: AppLocalizations.of(context)!.pmAddTitle,
    body: _AddFromManager(managers: managers, orchard: ref.read(activeSpaceProvider) is OrchardSpace),
  );
  if (picked == null || picked.$2.isEmpty) return null;
  final keyCrud = ref.read(identityCrudProvider);
  final hostCrud = ref.read(connectionCrudProvider);
  final user = Platform.environment['USER'] ?? Platform.environment['USERNAME'] ?? 'root';
  final done = await addFromPasswordManager(
    picked.$2,
    createKey: ({required label, required username, required passwordRef}) => keyCrud.create(
        label: label, username: username, authMethod: 'passwordManager', passwordRef: passwordRef),
    createHost: ({required label, required host, required port, required keyId}) =>
        hostCrud.create(label: label, host: host, port: port, identityId: keyId),
    fallbackUser: user,
  );
  ref.invalidate(identitiesProvider);
  return done;
}

class _AddFromManager extends StatefulWidget {
  const _AddFromManager({required this.managers, required this.orchard});

  final PasswordManagers managers;

  /// Added to an Orchard, where others see the items' names.
  final bool orchard;

  @override
  State<_AddFromManager> createState() => _AddFromManagerState();
}

class _AddFromManagerState extends State<_AddFromManager> {
  var _kind = PasswordManagerKind.onePassword;
  final _selection = ValueNotifier<List<PasswordManagerItem>>(const []);

  @override
  void dispose() {
    _selection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final tool = widget.managers.toolPath(_kind);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(l10n.pmAddNote, style: TextStyle(fontSize: 12.5, height: 1.4, color: AppColors.v3TextSecondary)),
        if (widget.orchard) ...[
          const SizedBox(height: 6),
          Text(l10n.pmAddOrchardNote,
              key: const ValueKey('pm-add-orchard'),
              style: TextStyle(fontSize: 12.5, height: 1.4, color: AppColors.v3Warning)),
        ],
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: ZestModeToggle(
            key: const ValueKey('pm-add-kind'),
            selectedId: _kind.code,
            onChanged: (id) {
              final kind = PasswordManagerKind.fromCode(id);
              if (kind == null || kind == _kind) return;
              setState(() {
                _kind = kind;
                _selection.value = const [];
              });
            },
            segments: [
              for (final k in PasswordManagerKind.values) ZestModeSegment(id: k.code, label: passwordManagerName(k)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // Not there: set up right here, then picked from.
        PasswordManagerToolSetup(
            key: ValueKey('pm-setup-in-add-${_kind.code}'), kind: _kind, onChanged: () => setState(() {})),
        if (tool != null) ...[
          const SizedBox(height: 10),
          _Picker(key: ValueKey('pm-add-${_kind.code}'), managers: widget.managers, kind: _kind, selection: _selection),
        ],
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: ValueListenableBuilder<List<PasswordManagerItem>>(
            valueListenable: _selection,
            builder: (context, picked, _) => FilledButton.icon(
              key: const ValueKey('pm-add-go'),
              onPressed: picked.isEmpty ? null : () => Navigator.of(context, rootNavigator: true).pop((_kind, picked)),
              icon: const Icon(LucideIcons.plus, size: 15),
              label: Text(l10n.pmAddCount(picked.length)),
            ),
          ),
        ),
      ],
    );
  }
}
