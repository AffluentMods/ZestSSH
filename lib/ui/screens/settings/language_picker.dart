import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/locale_providers.dart';
import 'package:zestssh/ui/screens/settings/widgets/choice_sheet.dart';

/// The current language's display label for a settings subtitle: the chosen
/// language's native name, or "System default" when following the system.
String currentLanguageLabel(BuildContext context, WidgetRef ref) {
  final l10n = AppLocalizations.of(context)!;
  final locale = ref.watch(appLocaleProvider);
  return locale == null
      ? l10n.settingsLanguageSystemDefault
      : localeDisplayName(locale);
}

/// The app language: "System default" plus every supported locale (grows
/// automatically as translated ARB files are added), in the app's sheet on a
/// phone and its dialog on a computer, the one in use checked. (A centred
/// Material dialog before, over the app bar on a phone.)
Future<void> showLanguagePickerDialog(
    BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context)!;
  final current = ref.read(appLocaleProvider);
  final locales = AppLocalizations.supportedLocales.toList()
    ..sort((a, b) =>
        localeDisplayName(a).toLowerCase().compareTo(
            localeDisplayName(b).toLowerCase()));
  final currentTag = current?.toLanguageTag();
  final picked = await showSettingsChoice<String?>(
    context,
    title: l10n.settingsLanguage,
    icon: LucideIcons.languages,
    current: currentTag != null && locales.any((l) => l.toLanguageTag() == currentTag) ? currentTag : null,
    choices: [
      (null, l10n.settingsLanguageSystemDefault),
      for (final locale in locales) (locale.toLanguageTag(), localeDisplayName(locale)),
    ],
    keyOf: (tag) => ValueKey('language-${tag ?? 'system'}'),
  );
  if (picked == null) return;
  final tag = picked.$1;
  ref.read(appLocaleProvider.notifier).set(
      tag == null ? null : locales.firstWhere((l) => l.toLanguageTag() == tag));
}
