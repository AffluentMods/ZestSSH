import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/report_scrub.dart';

/// A part of a public text as it goes, and whether it stands where the
/// person wrote something else (a host, an address, a username, a secret).
typedef PublicTextPart = ({String text, bool replaced});

/// What a public report says, once its words went through the same
/// scrubbing as diagnostics (ReportScrub; a 3.4 security review): a
/// public report is listed in every app and posted to Discord as it is
/// sent, so names and secrets typed into it are taken out before it goes.
class PublicText {
  PublicText(this.original) : scrubbed = ReportScrub.scrub(original);

  final String original;
  final String scrubbed;

  /// Whether something in it was taken out.
  bool get changed => scrubbed != original;

  /// [scrubbed] in parts, the words put in place of what was written
  /// marked.
  List<PublicTextPart> get parts => markReplacements(original, scrubbed);
}

final RegExp _token = RegExp(r'\s+|[^\s]+');

/// [after] in parts, with the words of it that are not in [before] (word by
/// word, in order) marked as replaced. Blanks are never marked.
List<PublicTextPart> markReplacements(String before, String after) {
  final a = [for (final m in _token.allMatches(before)) m[0]!];
  final b = [for (final m in _token.allMatches(after)) m[0]!];
  // The same at both ends: only what lies between is compared.
  var head = 0;
  while (head < a.length && head < b.length && a[head] == b[head]) {
    head++;
  }
  var tail = 0;
  while (tail < a.length - head && tail < b.length - head && a[a.length - 1 - tail] == b[b.length - 1 - tail]) {
    tail++;
  }
  final mid = b.sublist(head, b.length - tail);
  final from = a.sublist(head, a.length - tail);
  final kept = List<bool>.filled(mid.length, false);
  // The longest run in common (a few hundred words at most: the form's
  // limits); past that, all of the middle is marked.
  if (mid.length * from.length <= 4000000) {
    final n = from.length;
    final m = mid.length;
    final table = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
    for (var i = n - 1; i >= 0; i--) {
      for (var j = m - 1; j >= 0; j--) {
        table[i][j] = from[i] == mid[j] ? table[i + 1][j + 1] + 1 : (table[i + 1][j] >= table[i][j + 1] ? table[i + 1][j] : table[i][j + 1]);
      }
    }
    var i = 0;
    var j = 0;
    while (i < n && j < m) {
      if (from[i] == mid[j]) {
        kept[j] = true;
        i++;
        j++;
      } else if (table[i + 1][j] >= table[i][j + 1]) {
        i++;
      } else {
        j++;
      }
    }
  }
  final out = <PublicTextPart>[];
  void add(String text, bool replaced) {
    if (out.isNotEmpty && out.last.replaced == replaced) {
      out[out.length - 1] = (text: out.last.text + text, replaced: replaced);
    } else {
      out.add((text: text, replaced: replaced));
    }
  }

  for (final t in b.sublist(0, head)) {
    add(t, false);
  }
  for (var k = 0; k < mid.length; k++) {
    add(mid[k], !kept[k] && mid[k].trim().isNotEmpty);
  }
  for (final t in b.sublist(b.length - tail)) {
    add(t, false);
  }
  return out;
}

/// Before a public report or idea is sent: exactly what everyone will read,
/// each field ([fields]: its label and its text) as it goes, with what was
/// taken out marked. Returns the texts to send (scrubbed), in the order
/// given, or null where the person goes back to edit them.
Future<List<String>?> confirmPublicText(BuildContext context, List<({String label, String text})> fields) async {
  final l10n = AppLocalizations.of(context)!;
  final texts = [for (final f in fields) PublicText(f.text)];
  final changed = texts.any((t) => t.changed);
  final go = await showZestModal<bool>(
    context: context,
    size: ZestModalSize.standard,
    child: Builder(
      builder: (ctx) => ZestDialogShell(
        size: ZestModalSize.standard,
        tone: ZestDialogTone.neutral,
        icon: LucideIcons.globe,
        title: l10n.supportHubPublicPreviewTitle,
        subtitle: changed ? l10n.supportHubPublicPreviewChanged : l10n.supportHubPublicPreviewSame,
        body: Column(
          key: const ValueKey('hub-public-preview'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < fields.length; i++)
              if (texts[i].scrubbed.trim().isNotEmpty) ...[
                Text(fields[i].label,
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppColors.v3TextPrimary)),
                const SizedBox(height: 6),
                _MarkedBox(parts: texts[i].parts, valueKey: 'hub-public-preview-$i'),
                const SizedBox(height: 12),
              ],
          ],
        ),
        primaryKey: const ValueKey('hub-public-send'),
        primaryAction: (label: l10n.supportHubPublicPreviewSend, onPressed: () => Navigator.of(ctx).pop(true), icon: LucideIcons.send),
        secondaryKey: const ValueKey('hub-public-edit'),
        secondaryAction: (label: l10n.supportHubPublicPreviewEdit, onPressed: () => Navigator.of(ctx).pop(false)),
      ),
    ),
  );
  if (go != true) return null;
  return [for (final t in texts) t.scrubbed];
}

class _MarkedBox extends StatelessWidget {
  const _MarkedBox({required this.parts, required this.valueKey});

  final List<PublicTextPart> parts;
  final String valueKey;

  @override
  Widget build(BuildContext context) {
    final base = TextStyle(fontSize: 13, height: 1.45, color: AppColors.v3TextPrimary);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.v3Background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.v3BorderSubtle),
      ),
      child: SelectableText.rich(
        key: ValueKey(valueKey),
        TextSpan(
          style: base,
          children: [
            for (final p in parts)
              TextSpan(
                text: p.text,
                style: p.replaced
                    ? TextStyle(
                        fontWeight: FontWeight.w600,
                        color: AppColors.accentInk,
                        backgroundColor: AppColors.accentInk.withValues(alpha: 0.14),
                      )
                    : null,
              ),
          ],
        ),
      ),
    );
  }
}
