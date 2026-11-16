import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart' show AppDatabase, ConnectionGroup, Identity;
import 'package:zestssh/features/orchards/guardrails.dart';
import 'package:zestssh/features/orchards/team/team_providers.dart' show teamWatchedCratesProvider;
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart' show crateDisplayName;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/enums.dart' show ConnectionProtocol;
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/connection_tags_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/tags_field.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_color_picker.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';
import 'package:zestssh/ui/widgets/zest_sheet.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';

import '../state/kex_refused_hosts.dart';
import 'host_bulk_edit.dart';

/// The width of the bulk editor docked at the right of the Hosts page.
const double kHostBulkPanelWidth = 480;

/// A value of a select of the bulk editor: as each host has it.
const String _keep = '\u0000keep';

/// A value of a select of the bulk editor: none (no key, directly, no group).
const String _none = '\u0000none';

/// "Edit 42 hosts": every field of
/// the hosts [hostIds] as it is now, the fields changed by its person, and
/// one Apply that writes them to every host they may change. On a computer
/// it stands at the right of the Hosts page; on a phone, in a sheet
/// ([showHostBulkEditSheet]). [focus] is the field it opens on (Tags, Move to
/// group), scrolled to.
class HostBulkEditPanel extends ConsumerStatefulWidget {
  const HostBulkEditPanel({
    super.key,
    required this.hostIds,
    required this.onClose,
    this.focus,
    this.onApplied,
    this.onUnselect,
    this.phone = false,
  });

  /// The hosts selected, in the order shown.
  final List<String> hostIds;
  final BulkField? focus;

  /// Cancel, and the close button.
  final VoidCallback onClose;

  /// After the edit is written: what it did, and how many hosts it left as
  /// they were. Whoever opened the editor says so ([sayHostBulkApplied]),
  /// where the toast's Undo outlives the editor.
  final void Function(HostBulkOutcome outcome, int skipped)? onApplied;

  /// "Unselect them": the hosts that would be left as they are leave the
  /// selection.
  final void Function(Set<String> ids)? onUnselect;

  /// Drawn as a phone's sheet: the cards first, a field's label over it.
  final bool phone;

  @override
  ConsumerState<HostBulkEditPanel> createState() => HostBulkEditPanelState();
}

class HostBulkEditPanelState extends ConsumerState<HostBulkEditPanel> {
  final _port = TextEditingController();
  BulkSet<String?>? _identity;
  BulkSet<String?>? _jump;
  BulkCompat _compat = BulkCompat.keep;
  BulkSet<String?>? _group;
  BulkTagsMode _tagsMode = BulkTagsMode.add;
  List<String> _tags = const [];
  BulkSet<int?>? _color;
  bool _busy = false;

  final _anchors = {for (final f in BulkField.values) f: GlobalKey()};

  @override
  void initState() {
    super.initState();
    _port.addListener(() => setState(() {}));
    final focus = widget.focus;
    if (focus != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final at = _anchors[focus]?.currentContext;
        if (at != null && at.mounted) {
          unawaited(Scrollable.ensureVisible(at, duration: const Duration(milliseconds: 200), alignment: 0.1));
        }
      });
    }
  }

  @override
  void dispose() {
    _port.dispose();
    super.dispose();
  }

  /// The port typed, where it is one; null where the field is empty.
  int? get _portValue {
    final text = _port.text.trim();
    if (text.isEmpty) return null;
    final p = int.tryParse(text);
    return p != null && p >= 1 && p <= 65535 ? p : null;
  }

  bool get _portBad => _port.text.trim().isNotEmpty && _portValue == null;

  bool get _tagsChanged => _tags.isNotEmpty || _tagsMode == BulkTagsMode.replace;

  /// What Apply writes.
  HostBulkEdit get edit => HostBulkEdit(
        port: _portValue,
        identity: _identity,
        jumpHost: _jump,
        compat: _compat,
        group: _group,
        tags: _tagsChanged ? BulkTags(_tagsMode, _tags) : null,
        color: _color,
      );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final all = ref.watch(connectionsWithDetailsProvider).valueOrNull ?? const <ConnectionWithDetails>[];
    final byId = {for (final c in all) c.connection.id: c};
    final hosts = [for (final id in widget.hostIds) ?byId[id]];
    final rules = ItemRules.of(ref, 'host');
    final orchard = rules.orchard;
    String? vaultOf(String id) => orchard == null ? null : rules.crates[id] ?? orchard.defaultCrateId;
    final plan = planHostBulkEdit(
      [for (final h in hosts) h.connection.id],
      // While the team is still being read nothing is said skipped, and
      // nothing can be applied (below).
      mayChange: (id) => rules.loading || rules.mayChange(id),
      vaultOf: vaultOf,
    );
    final editable = [for (final id in plan.editable) byId[id]!];
    final refused = ref.watch(kexRefusedHostsProvider);
    final needing = {
      for (final c in editable)
        if (refused.contains(c.connection.id) && !c.connection.compatibilityMode && bulkTakesCompat(c.connection.protocol))
          c.connection.id,
    };
    final edit = this.edit;
    final changes = edit.changeCount;
    final canApply = changes > 0 && editable.isNotEmpty && !_portBad && !_busy && !rules.loading;

    final body = <Widget>[
      if (widget.phone) ...[
        _compatCard(l10n, hosts, editable, needing),
        const SizedBox(height: 12),
        _tagsCard(l10n, hosts),
        const SizedBox(height: 18),
        ..._connection(l10n, hosts, editable, orchard != null, vaultOf),
        const SizedBox(height: 18),
        ..._organize(l10n, hosts, withTags: false),
      ] else ...[
        ..._connection(l10n, hosts, editable, orchard != null, vaultOf),
        const SizedBox(height: 18),
        ZestSectionHeader(label: l10n.bulkSectionSecurity),
        _compatCard(l10n, hosts, editable, needing),
        const SizedBox(height: 18),
        ..._organize(l10n, hosts, withTags: true),
      ],
      const SizedBox(height: 8),
    ];

    final head = Padding(
      padding: EdgeInsets.fromLTRB(20, widget.phone ? 8 : 18, 10, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.bulkEditTitle(hosts.length),
                  key: const ValueKey('bulk-edit-title'),
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: ZestTokens.textPrimary),
                ),
                const SizedBox(height: 3),
                Text(
                  widget.phone ? l10n.bulkEditSubtitleShort : l10n.bulkEditSubtitle,
                  style: TextStyle(fontSize: 12.5, height: 1.35, color: ZestTokens.textTertiary),
                ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey('bulk-edit-close'),
            tooltip: l10n.cancel,
            onPressed: _busy ? null : widget.onClose,
            icon: Icon(LucideIcons.x, size: 18, color: ZestTokens.textSecondary),
          ),
        ],
      ),
    );

    final foot = Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: ZestTokens.borderSubtle))),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (plan.skippedCount > 0) ...[
            _SkippedCard(
              plan: plan,
              nameOf: (id) => _hostName(byId[id]),
              vaultName: (crateId) {
                final crate = orchard?.crates.where((c) => c.id == crateId).firstOrNull;
                return crate == null ? l10n.crateUnnamed : crateDisplayName(crate, l10n);
              },
              onUnselect: widget.onUnselect == null
                  ? null
                  : () => widget.onUnselect!({for (final l in plan.skipped.values) ...l}),
            ),
            const SizedBox(height: 12),
          ],
          Row(
            children: [
              Expanded(
                child: Text(
                  changes == 0 ? l10n.bulkNoChanges : l10n.bulkChangeCount(changes),
                  key: const ValueKey('bulk-edit-changes'),
                  style: TextStyle(fontSize: 13, color: ZestTokens.textTertiary),
                ),
              ),
              ZestButton(
                key: const ValueKey('bulk-edit-cancel'),
                label: l10n.cancel,
                variant: ZestButtonVariant.secondary,
                onPressed: _busy ? null : widget.onClose,
              ),
              const SizedBox(width: 8),
              ZestButton(
                key: const ValueKey('bulk-edit-apply'),
                label: l10n.bulkApply(editable.length),
                variant: ZestButtonVariant.primary,
                icon: LucideIcons.check,
                isLoading: _busy,
                onPressed: canApply ? () => _apply(editable, needing, skipped: plan.skippedCount) : null,
              ),
            ],
          ),
        ],
      ),
    );

    final content = Column(
      mainAxisSize: widget.phone ? MainAxisSize.min : MainAxisSize.max,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        head,
        Divider(height: 1, thickness: 1, color: ZestTokens.borderSubtle),
        Flexible(
          fit: widget.phone ? FlexFit.loose : FlexFit.tight,
          child: SingleChildScrollView(
            key: const ValueKey('bulk-edit-body'),
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: body),
          ),
        ),
        foot,
      ],
    );
    if (widget.phone) return content;
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape && !_busy) {
          widget.onClose();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Container(
      key: const ValueKey('host-bulk-edit-panel'),
      width: kHostBulkPanelWidth,
      decoration: BoxDecoration(
        color: ZestTokens.surfaceElevated,
        border: Border(left: BorderSide(color: ZestTokens.borderSubtle)),
      ),
      child: Material(type: MaterialType.transparency, child: content),
    ),
    );
  }

  String _hostName(ConnectionWithDetails? c) {
    if (c == null) return '';
    final name = c.connection.label.isNotEmpty ? c.connection.label : c.connection.host;
    return Redactable.host(name).displayIn(ref);
  }

  /// "root on 30, admin on 12": the values [values] take, the most common
  /// first; past two, [many] (or Mixed).
  String _summary(AppLocalizations l10n, List<String> values, {String Function(int n)? many}) {
    if (values.isEmpty) return l10n.bulkMixed;
    final counts = bulkValueCounts(values);
    if (counts.length == 1) return l10n.bulkOnAll(counts.single.value, counts.single.count);
    if (counts.length == 2) {
      return [for (final c in counts) l10n.bulkOnSome(c.value, c.count)].join(', ');
    }
    return many?.call(counts.length) ?? l10n.bulkMixed;
  }

  // ── Connection ───────────────────────────────────────────────────

  List<Widget> _connection(
    AppLocalizations l10n,
    List<ConnectionWithDetails> hosts,
    List<ConnectionWithDetails> editable,
    bool team,
    String? Function(String id) vaultOf,
  ) {
    final defaultUser = ref.watch(settingsServiceProvider).defaultUsername;
    final identities = ref.watch(identitiesProvider).valueOrNull ?? const <Identity>[];
    final all = ref.watch(connectionsWithDetailsProvider).valueOrNull ?? const <ConnectionWithDetails>[];
    final pro = ref.watch(isProProvider);

    final users = [
      for (final h in hosts)
        if (bulkTakesKey(h.connection.protocol)) Redactable.username(h.identity?.username ?? defaultUser).displayIn(ref),
    ];
    final ports = [
      for (final h in hosts)
        if (bulkTakesPort(h.connection.protocol)) '${h.connection.port}',
    ];
    final keys = [
      for (final h in hosts)
        if (bulkTakesKey(h.connection.protocol))
          h.identity == null ? l10n.bulkValueNone : Redactable.keyName(h.identity!.label).displayIn(ref),
    ];
    final names = {for (final c in all) c.connection.id: _hostName(c)};
    final jumps = [
      for (final h in hosts)
        if (bulkTakesJumpHost(h.connection.protocol))
          h.connection.connectViaId == null ? l10n.bulkValueNone : (names[h.connection.connectViaId] ?? l10n.bulkValueNone),
    ];

    // In a team's space, a key or a jump host of a vault whose sessions are
    // watched serves only that vault's own hosts.
    final orchardId = ItemRules.of(ref, 'host').orchard?.id;
    final watched = orchardId == null
        ? const <String>{}
        : ref.watch(teamWatchedCratesProvider(orchardId)).valueOrNull ?? const <String>{};
    final keyRules = ItemRules.of(ref, 'key');
    final keyOrchard = keyRules.orchard;
    final hostVaults = {for (final h in editable) vaultOf(h.connection.id)};
    final selected = {for (final h in hosts) h.connection.id};
    final byId = {for (final c in all) c.connection.id: c.connection};
    final offeredKeys = [
      for (final i in identities)
        if (bulkItemServesAll(
            keyOrchard == null ? null : keyRules.crates[i.id] ?? keyOrchard.defaultCrateId, hostVaults, watched))
          i,
    ];
    final offeredJumps = [
      for (final c in all)
        if (ConnectionProtocol.storedCanBeJumpHost(c.connection.protocol) &&
            bulkJumpHostFits(c.connection.id, selected, (id) => byId[id]?.connectViaId) &&
            bulkItemServesAll(vaultOf(c.connection.id), hostVaults, watched))
          c,
    ];

    String keyLabel(Identity i) =>
        '${Redactable.keyName(i.label).displayIn(ref)} (${Redactable.username(i.username).displayIn(ref)})';

    return [
      ZestSectionHeader(label: l10n.bulkSectionConnection),
      _FieldRow(
        phone: widget.phone,
        label: l10n.bulkFieldUsername,
        child: _StaticValue(
          key: const ValueKey('bulk-field-username'),
          text: l10n.bulkKeep(_summary(l10n, users)),
          tooltip: l10n.bulkUsernameNote,
        ),
      ),
      _FieldRow(
        key: _anchors[BulkField.port],
        phone: widget.phone,
        label: l10n.zestHostFieldPort,
        child: TextField(
          key: const ValueKey('bulk-field-port'),
          controller: _port,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(5)],
          style: const TextStyle(fontSize: 13, fontFamily: 'JetBrainsMono'),
          decoration: InputDecoration(
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: widget.phone ? 13 : 10),
            hintText: l10n.bulkKeep(_summary(l10n, ports)),
            hintStyle: TextStyle(fontSize: 13, fontFamily: 'GeistSans', color: ZestTokens.textSecondary),
            errorText: _portBad ? l10n.connectionPortInvalid : null,
          ),
        ),
      ),
      _FieldRow(
        key: _anchors[BulkField.key],
        phone: widget.phone,
        label: l10n.bulkFieldSignsInWith,
        child: ZestSelect<String>(
          key: const ValueKey('bulk-field-key'),
          value: _pickOf(_identity),
          accent: _identity != null,
          items: [
            ZestSelectItem(_keep, l10n.bulkKeep(_summary(l10n, keys, many: l10n.bulkDifferentKeys))),
            ZestSelectItem(_none, l10n.none),
            for (final i in offeredKeys) ZestSelectItem(i.id, keyLabel(i)),
          ],
          onChanged: (v) => setState(() => _identity = _setOf(v)),
        ),
      ),
      _FieldRow(
        key: _anchors[BulkField.jumpHost],
        phone: widget.phone,
        label: l10n.bulkFieldJumpHost,
        note: pro ? null : l10n.proFeature,
        child: ZestSelect<String>(
          key: const ValueKey('bulk-field-jump'),
          value: _pickOf(_jump),
          accent: _jump != null,
          items: [
            ZestSelectItem(_keep, l10n.bulkKeep(_summary(l10n, jumps))),
            ZestSelectItem(_none, l10n.connectionDirect),
            for (final c in offeredJumps) ZestSelectItem(c.connection.id, _hostName(c)),
          ],
          // A jump host is a Squeezed feature, as in the host editor.
          onChanged: pro ? (v) => setState(() => _jump = _setOf(v)) : null,
        ),
      ),
      if (team)
        Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 4),
          child: Text(
            l10n.bulkSharedOnly,
            key: const ValueKey('bulk-shared-only'),
            style: TextStyle(fontSize: 11.5, height: 1.4, color: ZestTokens.textTertiary),
          ),
        ),
    ];
  }

  static String _pickOf(BulkSet<String?>? set) => set == null ? _keep : set.value ?? _none;

  static BulkSet<String?>? _setOf(String pick) => switch (pick) {
        _keep => null,
        _none => const BulkSet<String?>(null),
        _ => BulkSet<String?>(pick),
      };

  // ── Security ─────────────────────────────────────────────────────

  Widget _compatCard(
    AppLocalizations l10n,
    List<ConnectionWithDetails> hosts,
    List<ConnectionWithDetails> editable,
    Set<String> needing,
  ) {
    final takes = [for (final h in editable) if (bulkTakesCompat(h.connection.protocol)) h];
    final now = _summary(l10n, [
      for (final h in hosts)
        if (bulkTakesCompat(h.connection.protocol))
          h.connection.compatibilityMode ? l10n.bulkValueOn : l10n.bulkValueOff,
    ]);
    final someNeed = needing.isNotEmpty && needing.length < takes.length;
    final names = [
      for (final h in hosts)
        if (needing.contains(h.connection.id)) _hostName(h),
    ];
    final on = _compat == BulkCompat.onAll || _compat == BulkCompat.onNeeding;
    final Widget control;
    if (widget.phone && !someNeed) {
      // A phone's switch, where every host would be turned on alike.
      control = Row(
        children: [
          Expanded(
            child: Text(l10n.bulkCompatAll(takes.length),
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
          ),
          ZestSwitch(
            key: const ValueKey('bulk-compat-switch'),
            value: _compat == BulkCompat.onAll,
            onChanged: takes.isEmpty
                ? null
                : (v) => setState(() => _compat = v ? BulkCompat.onAll : BulkCompat.off),
          ),
        ],
      );
    } else {
      control = _Segmented(
        keyPrefix: 'bulk-compat',
        selected: switch (_compat) {
          BulkCompat.keep => null,
          BulkCompat.off => 'off',
          BulkCompat.onNeeding => 'needing',
          BulkCompat.onAll => 'all',
        },
        segments: [
          (id: 'off', label: l10n.bulkCompatOff, enabled: takes.isNotEmpty),
          if (someNeed) (id: 'needing', label: l10n.bulkCompatNeeding(needing.length), enabled: true),
          (id: 'all', label: l10n.bulkCompatAll(takes.length), enabled: takes.isNotEmpty),
        ],
        onChanged: (id) => setState(() => _compat = switch (id) {
              'off' => BulkCompat.off,
              'needing' => BulkCompat.onNeeding,
              _ => BulkCompat.onAll,
            }),
      );
    }
    return _ChangeCard(
      key: _anchors[BulkField.compat],
      cardKey: const ValueKey('bulk-card-compat'),
      title: l10n.connectionEditCompatibilityMode,
      now: l10n.bulkNow(now),
      changed: _compat != BulkCompat.keep,
      onKeep: () => setState(() => _compat = BulkCompat.keep),
      children: [
        control,
        if (on) ...[
          const SizedBox(height: 10),
          _Warning(text: l10n.bulkCompatWarning),
        ],
        if (names.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            l10n.bulkCompatRefused(names.join(', ')),
            key: const ValueKey('bulk-compat-refused'),
            style: TextStyle(fontSize: 12, height: 1.45, color: ZestTokens.textSecondary),
          ),
        ],
      ],
    );
  }

  // ── Organize ─────────────────────────────────────────────────────

  Widget _tagsCard(AppLocalizations l10n, List<ConnectionWithDetails> hosts) {
    final assignments = ref.watch(allTagAssignmentsProvider).valueOrNull ?? const <String, List<String>>{};
    final known = ref.watch(allTagsProvider).valueOrNull ?? const <String>[];
    final sets = [
      for (final h in hosts) ([...?assignments[h.connection.id]]..sort()).join(', '),
    ];
    final distinct = sets.toSet();
    final now = distinct.length == 1
        ? l10n.bulkOnAll(distinct.single.isEmpty ? l10n.bulkValueNone : distinct.single, hosts.length)
        : l10n.bulkMixed;
    return _ChangeCard(
      key: _anchors[BulkField.tags],
      cardKey: const ValueKey('bulk-card-tags'),
      title: l10n.zestHostFieldTags,
      now: l10n.bulkNow(now),
      changed: _tagsChanged,
      onKeep: () => setState(() {
        _tagsMode = BulkTagsMode.add;
        _tags = const [];
      }),
      children: [
        _Segmented(
          keyPrefix: 'bulk-tags',
          selected: _tagsMode.name,
          segments: [
            (id: BulkTagsMode.add.name, label: l10n.bulkTagsAdd, enabled: true),
            (id: BulkTagsMode.remove.name, label: l10n.bulkTagsRemove, enabled: true),
            (id: BulkTagsMode.replace.name, label: l10n.bulkTagsReplace, enabled: true),
          ],
          onChanged: (id) => setState(() => _tagsMode = BulkTagsMode.values.byName(id)),
        ),
        const SizedBox(height: 10),
        TagsField(
          key: const ValueKey('bulk-tags-field'),
          tags: _tags,
          availableTags: known,
          hintText: l10n.bulkTagsHint,
          onChanged: (tags) => setState(() => _tags = bulkCanonicalTags(tags)),
        ),
        if (_tagsMode == BulkTagsMode.replace && _tags.isEmpty) ...[
          const SizedBox(height: 8),
          Text(l10n.bulkTagsReplaceNone, style: TextStyle(fontSize: 12, color: ZestTokens.statusWarning)),
        ],
      ],
    );
  }

  List<Widget> _organize(AppLocalizations l10n, List<ConnectionWithDetails> hosts, {required bool withTags}) {
    final groups = [...(ref.watch(connectionGroupsProvider).valueOrNull ?? const <ConnectionGroup>[])]
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    final groupNames = [
      for (final h in hosts)
        h.group == null ? l10n.zestGroupUngrouped : Redactable.group(h.group!.name).displayIn(ref),
    ];
    final color = _color;
    return [
      ZestSectionHeader(label: l10n.bulkSectionOrganize),
      _FieldRow(
        key: _anchors[BulkField.group],
        phone: widget.phone,
        label: l10n.zestHostFieldGroup,
        child: ZestSelect<String>(
          key: const ValueKey('bulk-field-group'),
          value: _pickOf(_group),
          accent: _group != null,
          items: [
            ZestSelectItem(_keep, l10n.bulkKeep(_summary(l10n, groupNames))),
            ZestSelectItem(_none, l10n.zestGroupUngrouped),
            for (final g in groups) ZestSelectItem(g.id, Redactable.group(g.name).displayIn(ref)),
          ],
          onChanged: (v) => setState(() => _group = _setOf(v)),
        ),
      ),
      if (withTags) ...[
        const SizedBox(height: 4),
        _tagsCard(l10n, hosts),
      ],
      const SizedBox(height: 12),
      _ChangeCard(
        key: _anchors[BulkField.color],
        cardKey: const ValueKey('bulk-card-color'),
        title: l10n.zestHostFieldColor,
        changed: color != null,
        onKeep: () => setState(() => _color = null),
        children: [
          ZestColorPicker(
            presets: AppColors.labelPalette,
            // Nothing is common to the hosts until a colour is picked here.
            selected: Color(color?.value ?? 0x00000000),
            allowCustom: false,
            allowNone: true,
            noneSelected: color != null && color.value == null,
            onNoneSelected: () => setState(() => _color = const BulkSet<int?>(null)),
            onChanged: (c) => setState(() => _color = BulkSet<int?>(c.toARGB32())),
          ),
        ],
      ),
    ];
  }

  // ── Apply ────────────────────────────────────────────────────────

  Future<void> _apply(List<ConnectionWithDetails> editable, Set<String> needing, {required int skipped}) async {
    final l10n = AppLocalizations.of(context)!;
    final db = ref.read(databaseProvider);
    setState(() => _busy = true);
    try {
      final outcome = await applyHostBulkEdit(db, [for (final c in editable) c.connection.id], edit, needCompat: needing);
      if (!mounted) return;
      widget.onApplied?.call(outcome, skipped);
    } catch (e) {
      if (!mounted) return;
      final refused = isOrchardWriteRefused(e);
      showTopSnackBar(
        context,
        refused ? l10n.orchardWriteNotAllowed : l10n.connectionNotSaved,
        isError: true,
        details: refused ? null : '$e',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// Says what a bulk edit did, in [context] (the page it was made on, which
/// outlives the editor): "40 hosts changed. 2 skipped.", with Undo, which
/// writes back what the hosts had, in one transaction.
void sayHostBulkApplied(BuildContext context, AppDatabase db, HostBulkOutcome outcome, {required int skipped}) {
  final l10n = AppLocalizations.of(context)!;
  final said = [
    l10n.bulkAppliedChanged(outcome.changed.length),
    if (skipped > 0) l10n.bulkAppliedSkipped(skipped),
  ].join(' ');
  final undo = outcome.undo;
  showTopSnackBar(
    context,
    said,
    isSuccess: true,
    actionLabel: undo.isEmpty ? null : l10n.hostsSelUndo,
    onAction: undo.isEmpty
        ? null
        : () async {
            try {
              await undoHostBulkEdit(db, undo);
            } catch (e) {
              if (!context.mounted) return;
              final refused = isOrchardWriteRefused(e);
              showTopSnackBar(context, refused ? l10n.orchardWriteNotAllowed : l10n.connectionNotSaved,
                  isError: true, details: refused ? null : '$e');
            }
          },
  );
}

/// Opens the bulk editor of [hostIds] in a phone's sheet.
Future<void> showHostBulkEditSheet(
  BuildContext context, {
  required List<String> hostIds,
  BulkField? focus,
  void Function(HostBulkOutcome outcome, int skipped)? onApplied,
  void Function(Set<String> ids)? onUnselect,
}) {
  return showZestSheet<void>(
    context: context,
    child: Builder(
      builder: (sheet) => ZestSheetFrame(
        child: HostBulkEditPanel(
          phone: true,
          hostIds: hostIds,
          focus: focus,
          onClose: () => Navigator.of(sheet).pop(),
          onApplied: (outcome, skipped) {
            Navigator.of(sheet).pop();
            onApplied?.call(outcome, skipped);
          },
          onUnselect: onUnselect == null
              ? null
              : (ids) {
                  Navigator.of(sheet).pop();
                  onUnselect(ids);
                },
        ),
      ),
    ),
  );
}

/// A field of the editor: its name at the left and its control beside it on
/// a computer; on a phone, its name over it.
class _FieldRow extends StatelessWidget {
  const _FieldRow({super.key, required this.phone, required this.label, required this.child, this.note});

  final bool phone;
  final String label;
  final Widget child;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final name = Text(label, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500, color: ZestTokens.textPrimary));
    final under = note == null
        ? child
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              child,
              const SizedBox(height: 4),
              Text(note!, style: TextStyle(fontSize: 11.5, color: ZestTokens.textTertiary)),
            ],
          );
    if (phone) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [name, const SizedBox(height: 6), under],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 120, child: Padding(padding: const EdgeInsets.only(top: 8), child: name)),
          const SizedBox(width: 8),
          Expanded(child: under),
        ],
      ),
    );
  }
}

/// A value that is not changed here (the username comes with the key): in
/// the field's box, with why in its tooltip.
class _StaticValue extends StatelessWidget {
  const _StaticValue({super.key, required this.text, required this.tooltip});

  final String text;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Container(
        constraints: const BoxConstraints(minHeight: 34),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: ZestTokens.surfaceSunken,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: ZestTokens.borderSubtle),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: ZestTokens.textSecondary)),
            ),
            Icon(LucideIcons.info, size: 14, color: ZestTokens.textPlaceholder),
          ],
        ),
      ),
    );
  }
}

/// A field drawn as a card (Compatibility mode, Tags, the colour label):
/// its name, "Changed" once changed (with an outline in the brand's colour),
/// "Keep as is" to undo that, what it is now, and its controls.
class _ChangeCard extends StatelessWidget {
  const _ChangeCard({
    super.key,
    required this.cardKey,
    required this.title,
    required this.changed,
    required this.onKeep,
    required this.children,
    this.now,
  });

  final Key cardKey;
  final String title;
  final String? now;
  final bool changed;
  final VoidCallback onKeep;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final brand = ZestTokens.brand;
    return Container(
      key: cardKey,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: changed ? Color.alphaBlend(brand.withValues(alpha: 0.05), ZestTokens.surfaceRaisedAlt) : ZestTokens.surfaceRaisedAlt,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: changed ? brand.withValues(alpha: 0.75) : ZestTokens.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(title,
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: ZestTokens.textPrimary)),
                    ),
                    if (changed) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: brand.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(l10n.bulkChanged,
                            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: ZestTokens.brandInk)),
                      ),
                    ],
                  ],
                ),
              ),
              if (changed)
                TextButton.icon(
                  key: ValueKey('bulk-keep-${(cardKey as ValueKey<String>).value}'),
                  onPressed: onKeep,
                  style: TextButton.styleFrom(
                    foregroundColor: ZestTokens.textSecondary,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    minimumSize: const Size(0, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: const Icon(LucideIcons.rotateCcw, size: 13),
                  label: Text(l10n.bulkKeepAsIs, style: const TextStyle(fontSize: 12.5)),
                ),
            ],
          ),
          if (now != null) ...[
            const SizedBox(height: 2),
            Text(now!, style: TextStyle(fontSize: 12, color: ZestTokens.textTertiary)),
          ],
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }
}

/// What turning Compatibility mode on costs, in the warning's colours.
class _Warning extends StatelessWidget {
  const _Warning({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final warn = ZestTokens.statusWarning;
    return Container(
      key: const ValueKey('bulk-compat-warning'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: warn.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: warn.withValues(alpha: 0.45)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.alertTriangle, size: 15, color: warn),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: TextStyle(fontSize: 12.5, height: 1.4, color: ZestTokens.textSecondary))),
        ],
      ),
    );
  }
}

/// "2 hosts will be skipped": the hosts its person may not change, by the
/// vault they are in, and Unselect them.
class _SkippedCard extends StatelessWidget {
  const _SkippedCard({required this.plan, required this.nameOf, required this.vaultName, this.onUnselect});

  final HostBulkPlan plan;
  final String Function(String id) nameOf;
  final String Function(String? crateId) vaultName;
  final VoidCallback? onUnselect;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      key: const ValueKey('bulk-skipped'),
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 12),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceRaisedAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ZestTokens.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.lock, size: 14, color: ZestTokens.textSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(l10n.bulkSkippedTitle(plan.skippedCount),
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
              ),
              if (onUnselect != null)
                TextButton(
                  key: const ValueKey('bulk-skipped-unselect'),
                  onPressed: onUnselect,
                  style: TextButton.styleFrom(
                    foregroundColor: ZestTokens.textSecondary,
                    minimumSize: const Size(0, 28),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(l10n.bulkUnselectThem, style: const TextStyle(fontSize: 12.5)),
                ),
            ],
          ),
          for (final MapEntry(key: crate, value: ids) in plan.skipped.entries) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 22),
              child: Text(
                l10n.bulkSkippedIn(ids.length, ids.map(nameOf).join(', '), vaultName(crate)),
                style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textSecondary),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A choice of a few, side by side across the card's width, each as wide as
/// the others and its words on two lines where they need them: the
/// segments. None is chosen while [selected] is null (as each host
/// has it).
class _Segmented extends StatelessWidget {
  const _Segmented({required this.keyPrefix, required this.selected, required this.segments, required this.onChanged});

  final String keyPrefix;
  final String? selected;
  final List<({String id, String label, bool enabled})> segments;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceSunken,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: ZestTokens.border),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final s in segments)
              Expanded(
                child: Semantics(
                  button: true,
                  selected: s.id == selected,
                  child: Material(
                    key: ValueKey('$keyPrefix-${s.id}'),
                    color: s.id == selected ? ZestTokens.surfaceChipStrong : Colors.transparent,
                    borderRadius: BorderRadius.circular(7),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(7),
                      onTap: s.enabled ? () => onChanged(s.id) : null,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
                        child: Center(
                          child: Text(
                            s.label,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              height: 1.25,
                              fontWeight: s.id == selected ? FontWeight.w600 : FontWeight.w500,
                              color: !s.enabled
                                  ? ZestTokens.textPlaceholder
                                  : s.id == selected
                                      ? ZestTokens.textPrimary
                                      : ZestTokens.textSecondary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
