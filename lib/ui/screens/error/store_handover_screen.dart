import 'package:flutter/material.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/locale_providers.dart' show resolveAppLocale;
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/l10n/time_text.dart';

/// The Store's copy of ZestSSH on Windows, at its first start after the website's
/// copy handed its data over, where it holds data of its own that is not the same
/// (lib/services/store_handover.dart): which to keep. What is not kept is set aside
/// on this PC, never deleted. Like the moving-data screen it runs before anything
/// else, as its own MaterialApp with nothing of the app behind it.
class StoreHandoverQuestionApp extends StatelessWidget {
  const StoreHandoverQuestionApp({
    super.key,
    required this.onAnswer,
    this.language,
    this.websiteLastUsed,
    this.storeLastUsed,
  });

  /// Told true to keep the website copy's data, false to keep this copy's own.
  final ValueChanged<bool> onAnswer;

  /// The language the person chose, where they did: a language code.
  final String? language;

  /// When each set of data was last used (its newest file), said under its
  /// button: one handed over long ago is the older (found in a code review).
  /// Null where it is not known.
  final DateTime? websiteLastUsed;
  final DateTime? storeLastUsed;

  @override
  Widget build(BuildContext context) {
    final code = language;
    return MaterialApp(
      title: 'ZestSSH',
      debugShowCheckedModeBanner: false,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      localeListResolutionCallback: resolveAppLocale,
      locale: code == null || code.isEmpty ? null : Locale(code),
      // The app's own colours: the default dark theme's are purple.
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: AppColors.background,
        colorScheme: ColorScheme.dark(
          primary: AppColors.orange,
          onPrimary: AppColors.onBrand(AppColors.orange),
          surface: AppColors.background,
          onSurface: AppColors.onSurface,
          outline: AppColors.divider,
        ),
      ),
      home: _StoreHandoverQuestion(
        onAnswer: onAnswer,
        websiteLastUsed: websiteLastUsed,
        storeLastUsed: storeLastUsed,
      ),
    );
  }
}

class _StoreHandoverQuestion extends StatefulWidget {
  const _StoreHandoverQuestion({
    required this.onAnswer,
    this.websiteLastUsed,
    this.storeLastUsed,
  });

  final ValueChanged<bool> onAnswer;
  final DateTime? websiteLastUsed;
  final DateTime? storeLastUsed;

  @override
  State<_StoreHandoverQuestion> createState() => _StoreHandoverQuestionState();
}

class _StoreHandoverQuestionState extends State<_StoreHandoverQuestion> {
  bool _answered = false;

  void _answer(bool keepWebsite) {
    if (_answered) return;
    setState(() => _answered = true);
    widget.onAnswer(keepWebsite);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    Widget lastUsed(DateTime? at) => at == null
        ? const SizedBox(height: 10)
        : Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 12),
            child: Text(
              plainTimeSpaces(l10n.storeHandoverLastUsed(at.toLocal(), at.toLocal())),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: AppColors.onSurfaceVariant),
            ),
          );
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(40),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l10n.storeHandoverAskTitle,
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: AppColors.onBackground),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    l10n.storeHandoverAskBody,
                    style: TextStyle(fontSize: 14, color: AppColors.onBackground, height: 1.5),
                  ),
                  const SizedBox(height: 28),
                  FilledButton(
                    onPressed: _answered ? null : () => _answer(false),
                    style: FilledButton.styleFrom(backgroundColor: AppColors.brandOrange),
                    child: Text(l10n.storeHandoverKeepStore),
                  ),
                  lastUsed(widget.storeLastUsed),
                  OutlinedButton(
                    onPressed: _answered ? null : () => _answer(true),
                    child: Text(l10n.storeHandoverKeepWebsite),
                  ),
                  if (widget.websiteLastUsed != null) lastUsed(widget.websiteLastUsed),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
