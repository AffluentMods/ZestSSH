import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/widgets/orchard_crates.dart' show VaultTab;
import 'package:zestssh/ui/widgets/zest_select.dart';

/// The Vaults window shows one vault at a time, its settings under four tabs
/// (the 4.0 design): brings [finder] into view by choosing
/// the vault and the tab that hold it, the vault shown and the tab chosen
/// first. True when it is there (at once where it already was).
Future<bool> showInVaults(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isNotEmpty) return true;
  Future<void> frames() async {
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  // The vaults the window lists: its list on a computer, its picker on a
  // phone; the one shown first.
  String? idOf(Key? key) {
    final v = key is ValueKey<String> ? key.value : null;
    return v != null && v.startsWith('vault-item-') ? v.substring('vault-item-'.length) : null;
  }

  final listed = [
    for (final e in find.byWidgetPredicate((w) => idOf(w.key) != null).evaluate()) idOf(e.widget.key)!,
  ];
  final picker = find.byKey(const ValueKey('vault-picker'));
  final ids = listed.isNotEmpty
      ? listed
      : picker.evaluate().isEmpty
          ? <String>[]
          : [for (final i in tester.widget<ZestSelect<String>>(picker).items) i.value];
  String? shown() {
    for (final e in find.byWidgetPredicate((w) {
      final v = w.key is ValueKey<String> ? (w.key! as ValueKey<String>).value : '';
      return v.startsWith('vault-detail-') && !v.startsWith('vault-detail-name-') && !v.startsWith('vault-detail-line-');
    }).evaluate()) {
      return (e.widget.key! as ValueKey<String>).value.substring('vault-detail-'.length);
    }
    return null;
  }

  final first = shown();
  final order = [?first, for (final id in ids) if (id != first) id];
  for (final id in order) {
    if (shown() != id) {
      if (listed.contains(id)) {
        final item = find.byKey(ValueKey('vault-item-$id'));
        await tester.ensureVisible(item);
        await tester.tap(item);
      } else {
        tester.widget<ZestSelect<String>>(picker).onChanged!(id);
      }
      await frames();
    }
    for (final tab in VaultTab.values) {
      final t = find.byKey(ValueKey('vault-tab-${tab.name}'));
      if (t.evaluate().isEmpty) continue;
      await tester.ensureVisible(t);
      await tester.tap(t);
      await frames();
      if (finder.evaluate().isNotEmpty) return true;
    }
  }
  return finder.evaluate().isNotEmpty;
}

/// In the Vaults window, shows the vault [crateId] (its list's item on a
/// computer, its picker on a phone) on its [tab].
Future<void> openVaultTab(WidgetTester tester, String crateId, VaultTab tab) async {
  Future<void> frames() async {
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  if (find.byKey(ValueKey('vault-detail-$crateId')).evaluate().isEmpty) {
    final item = find.byKey(ValueKey('vault-item-$crateId'));
    if (item.evaluate().isNotEmpty) {
      await tester.ensureVisible(item);
      await tester.tap(item);
    } else {
      tester.widget<ZestSelect<String>>(find.byKey(const ValueKey('vault-picker'))).onChanged!(crateId);
    }
    await frames();
  }
  final t = find.byKey(ValueKey('vault-tab-${tab.name}'));
  await tester.ensureVisible(t);
  await tester.tap(t);
  await frames();
}
