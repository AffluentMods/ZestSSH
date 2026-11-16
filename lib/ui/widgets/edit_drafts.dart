import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/providers/core_providers.dart' show activeSpaceProvider;

/// An editor's unsaved edits while its page is away. The desktop shell shows
/// a terminal in the place of every page, and each page goes with everything
/// it held; an editor that goes with unsaved edits keeps them here, and its
/// page opens the same form again with them, shown unsaved, as it comes back.
///
/// Kept by the key of what was being edited (its id, or the key of a new
/// item's form), with the space it was edited in: a draft kept in one space
/// does not come back in another, where it would be saved to the wrong place.
///
/// In memory only: never written to disk or to the preferences, gone when the
/// app closes. A page takes its draft back as it opens, so nothing is kept
/// here while the page is on screen; it keeps one only as it goes with
/// unsaved edits. A change of profile builds the provider again, empty
/// ([editDraftsProvider]).
class EditDrafts<T> {
  EditDrafts({void Function(T draft)? onForget}) : _onForget = onForget;

  /// What a draft that is let go needs done (a kept editor is disposed).
  final void Function(T draft)? _onForget;

  final Map<String, ({T draft, Object? scope})> _byKey = {};

  /// The key of the form that was open with unsaved edits as the page went,
  /// which the page opens again as it comes back.
  String? openKey;

  bool get isEmpty => _byKey.isEmpty;

  /// Keep [draft] under [key], edited in [scope], and open it again when the
  /// page comes back.
  void keep(String key, T draft, {Object? scope}) {
    final before = _byKey[key];
    _byKey[key] = (draft: draft, scope: scope);
    openKey = key;
    if (before != null && !identical(before.draft, draft)) {
      _onForget?.call(before.draft);
    }
  }

  /// Take the draft kept under [key]: it is the page's again, and no longer
  /// kept here.
  T? take(String key) {
    if (openKey == key) openKey = null;
    return _byKey.remove(key)?.draft;
  }

  /// Take the draft that was open as the page went, where it was kept in
  /// [scope]; one kept in another space is let go.
  T? takeOpen({Object? scope}) {
    final key = openKey;
    if (key == null) return null;
    final kept = _byKey[key];
    if (kept != null && kept.scope != scope) {
      forget(key);
      return null;
    }
    return take(key);
  }

  /// Let the draft kept under [key] go (its item was saved or deleted, or
  /// its edits discarded).
  void forget(String key) {
    final kept = _byKey.remove(key);
    if (openKey == key) openKey = null;
    if (kept != null) _onForget?.call(kept.draft);
  }

  /// Let every draft go.
  void forgetAll() {
    final all = _byKey.values.toList();
    _byKey.clear();
    openKey = null;
    for (final kept in all) {
      _onForget?.call(kept.draft);
    }
  }
}

/// A provider of one editor's [EditDrafts]. Not auto-disposed: it outlives the
/// page, which is what it is for. A change of profile builds it again, empty,
/// and lets go of what it kept ([onForget] for each).
Provider<EditDrafts<T>> editDraftsProvider<T>({
  void Function(T draft)? onForget,
}) => Provider<EditDrafts<T>>((ref) {
  final drafts = EditDrafts<T>(onForget: onForget);
  ref.onDispose(drafts.forgetAll);
  return drafts;
});

/// A page whose editor keeps its unsaved edits while the page is away
/// ([EditDrafts]).
mixin KeepsEditDrafts<W extends ConsumerStatefulWidget, T> on ConsumerState<W> {
  /// Where the page keeps its edits. Null between a change of profile and the
  /// reset that follows it: nothing of the profile before is kept for the next.
  EditDrafts<T>? _editDrafts;

  /// The space on screen, which a draft is kept with.
  Object? _editSpace;

  /// Called from initState: starts keeping edits in [drafts], and gives back
  /// the draft that was open as the page went, if any, for the page to open.
  /// [onRenewed] resets the form when a change of profile builds the drafts
  /// anew: the form open then was the profile before's.
  T? takeEditDraft(
    ProviderListenable<EditDrafts<T>> drafts, {
    required VoidCallback onRenewed,
  }) {
    final current = ref.read(drafts);
    _editDrafts = current;
    ref.listenManual<Object?>(
      activeSpaceProvider,
      (_, space) => _editSpace = space,
      fireImmediately: true,
    );
    ref.listenManual<EditDrafts<T>>(drafts, (_, next) {
      _editDrafts = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        onRenewed();
        _editDrafts = next;
      });
      WidgetsBinding.instance.scheduleFrame();
    });
    return current.takeOpen(scope: _editSpace);
  }

  /// Keeps [draft] under [key] as the page goes. False where nothing can be
  /// kept (between a change of profile and its reset).
  bool keepEditDraft(String key, T draft) {
    final drafts = _editDrafts;
    if (drafts == null) return false;
    drafts.keep(key, draft, scope: _editSpace);
    return true;
  }

  /// Lets the draft kept under [key] go.
  void forgetEditDraft(String key) => _editDrafts?.forget(key);
}
