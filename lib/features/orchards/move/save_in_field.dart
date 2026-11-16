import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/move/item_transfer.dart';
import 'package:zestssh/features/orchards/move/move_copy_dialog.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

// "Save in" (3.4): at the top of a new host's, key's, snippet's or port
// forward's editor, where it is saved: the place new items of the space on
// screen go, or any other place the picker lists.

/// Saves a new item an editor makes with [write] (which returns its key) at
/// [place]. Where that is the place new items of the space on screen go,
/// [write] alone, as before. Anywhere else, what [write] makes is captured and
/// never kept on screen's space ([captureNewItem]), then saved at [place]
/// as Copy to... saves an item there, after the question about what it uses
/// that [place] does not have. Resolves with the item's key where it was
/// saved, or null where it was not (the question closed, or it could not be:
/// said here).
Future<String?> saveNewItemIn(
  BuildContext context,
  WidgetRef ref, {
  required SavePlace place,
  required String kind,
  required Future<String> Function() write,
}) async {
  if (place == defaultSavePlace(ref)) return write();
  final draft = await captureNewItem(ref.read(databaseProvider), ref.read(secureStorageProvider), kind, write);
  if (!context.mounted) return null;
  final result = await saveDraftIn(context, ref, draft: draft, to: place);
  if (result == null) return null;
  if (result.done == 0) {
    if (context.mounted) {
      final l10n = AppLocalizations.of(context)!;
      final problem = result.failed.firstOrNull;
      showTopSnackBar(
        context,
        problem == null ? l10n.transferWhyFailed : transferWhy(l10n, problem.reason, link: problem.link),
        isError: true,
      );
    }
    return null;
  }
  return result.newKeys[draft.key] ?? draft.key;
}

/// "Save in" at the top of a new item's editor: [value] (null: where new items
/// of the space on screen go), one of the places the picker lists. Nothing
/// where there is no other place.
class SaveInField extends ConsumerWidget {
  const SaveInField({super.key, required this.value, required this.onChanged, this.padding = EdgeInsets.zero});

  final SavePlace? value;
  final ValueChanged<SavePlace> onChanged;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final places = savePlaces(ref, l10n);
    if (places.length < 2) return const SizedBox.shrink();
    final current = value ?? defaultSavePlace(ref);
    final chosen = places.where((p) => p.place == current).firstOrNull ?? places.first;
    final elsewhere = chosen.place.space != ref.watch(activeSpaceProvider);
    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(l10n.saveInLabel, style: TextStyle(fontSize: 12.5, color: AppColors.v3TextSecondary)),
              const SizedBox(width: 12),
              Flexible(
                child: Builder(
                  builder: (anchor) => _PlaceButton(
                    key: const ValueKey('save-in'),
                    choice: chosen,
                    onTap: () => _open(anchor, places, chosen),
                  ),
                ),
              ),
            ],
          ),
          if (elsewhere)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                l10n.saveInLinksNote,
                key: const ValueKey('save-in-note'),
                style: TextStyle(fontSize: 11.5, height: 1.35, color: AppColors.v3TextTertiary),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _open(BuildContext anchor, List<PlaceChoice> places, PlaceChoice chosen) async {
    final box = anchor.findRenderObject();
    final overlay = Overlay.of(anchor).context.findRenderObject();
    if (box is! RenderBox || overlay is! RenderBox) return;
    final at = Rect.fromPoints(
      box.localToGlobal(Offset(0, box.size.height + 4), ancestor: overlay),
      box.localToGlobal(box.size.bottomRight(const Offset(0, 4)), ancestor: overlay),
    );
    final picked = await showMenu<SavePlace>(
      context: anchor,
      position: RelativeRect.fromRect(at, Offset.zero & overlay.size),
      color: AppColors.v3Elevated,
      constraints: const BoxConstraints(minWidth: 240, maxWidth: 360),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: AppColors.v3BorderSubtle),
      ),
      items: [
        for (final p in places)
          PopupMenuItem<SavePlace>(
            key: ValueKey('save-in-${p.place.orchardId ?? 'personal'}-${p.place.crateId ?? ''}'),
            value: p.place,
            height: 38,
            child: Row(
              children: [
                Icon(
                  p.team == null ? LucideIcons.user : (p.ownersOnly ? LucideIcons.lock : LucideIcons.package),
                  size: 15,
                  color: AppColors.v3TextSecondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: RedactedText(
                    Redactable.freeText(p.title),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.v3TextPrimary,
                      fontWeight: p.place == chosen.place ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
                if (p.place == chosen.place) Icon(LucideIcons.check, size: 14, color: AppColors.v3TextPrimary),
              ],
            ),
          ),
      ],
    );
    if (picked != null) onChanged(picked);
  }
}

class _PlaceButton extends StatelessWidget {
  const _PlaceButton({super.key, required this.choice, required this.onTap});

  final PlaceChoice choice;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.v3BorderSubtle),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  choice.team == null ? LucideIcons.user : (choice.ownersOnly ? LucideIcons.lock : LucideIcons.package),
                  size: 14,
                  color: AppColors.v3TextSecondary,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: RedactedText(
                    Redactable.freeText(choice.title),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: AppColors.v3TextPrimary),
                  ),
                ),
                const SizedBox(width: 6),
                Icon(LucideIcons.chevronDown, size: 14, color: AppColors.v3TextTertiary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
