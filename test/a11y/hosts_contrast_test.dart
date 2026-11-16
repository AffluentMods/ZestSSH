import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/theme/zest_tokens.dart';

import 'hosts_a11y_harness.dart';

/// The contrast of the words on the Hosts area's screens (4.0, the
/// accessibility pass), held at the colours themselves in Ember, Graphite and
/// Daylight: body text at 4.5:1 or better on every surface it is drawn on.
/// (Flutter's own check reads colours off the picture and misjudges small
/// antialiased text: see hosts_a11y_test.dart.)
void main() {
  for (final id in a11yThemes) {
    test('the words of the Hosts area read at 4.5:1 or better in $id', () {
      AppColors.applyTheme(BuiltInThemes.getById(id).colorScheme);
      final surfaces = {
        'page': ZestTokens.surfaceBase,
        'raised': ZestTokens.surfaceRaised,
        'elevated': ZestTokens.surfaceElevated,
        'sunken': ZestTokens.surfaceSunken,
        'band': ZestTokens.band,
      };
      final words = {
        'textPrimary': ZestTokens.textPrimary,
        'textSecondary': ZestTokens.textSecondary,
        // Addresses, hints, Ungrouped, a muted reading, a tag's cross
        // (the turned-off grey they had was under 3:1).
        'textTertiary': ZestTokens.textTertiary,
        'textMuted': ZestTokens.textMuted,
        'brandInk': ZestTokens.brandInk,
        // Networks' and the import's quiet lines (Daylight's was 4.3:1).
        'v3TextTertiary': AppColors.v3TextTertiary,
      };
      final failures = <String>[];
      for (final w in words.entries) {
        for (final s in surfaces.entries) {
          final r = ZestColors.contrast(w.value, s.value);
          if (r < 4.5) failures.add('${w.key} on ${s.key}: ${r.toStringAsFixed(2)}');
        }
      }
      // A count on its chip (the section heads', the import's).
      final chip = ZestColors.contrast(ZestTokens.textTertiary, ZestTokens.surfaceChip);
      if (chip < 4.5) failures.add('textTertiary on surfaceChip: ${chip.toStringAsFixed(2)}');
      // Delete on the selection bar, in its red as text.
      final delete = ZestColors.contrast(ZestColors.inkOn(ZestColors.statusError, ZestColors.bgElevated), ZestColors.bgElevated);
      if (delete < 4.5) failures.add('Delete on the selection bar: ${delete.toStringAsFixed(2)}');
      expect(failures, isEmpty, reason: failures.join('\n'));
    });
  }
}
