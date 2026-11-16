import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// The list-pane filter field shared by the desktop master/detail screens
/// (Snippets, Triggers, Command history): 36px, surface fill, subtle border
/// that turns brand on focus, a search glyph that follows it, and a clear
/// button once there is text. One widget so the panes cannot drift apart.
class ZestListSearchField extends StatefulWidget {
  const ZestListSearchField({
    super.key,
    required this.controller,
    required this.hintText,
    required this.onChanged,
    this.focusNode,
    this.onSubmitted,
  });

  final TextEditingController controller;

  /// Already-localized placeholder.
  final String hintText;
  final ValueChanged<String> onChanged;
  final FocusNode? focusNode;

  /// Enter in the field, which keeps the focus: with nothing to open, the
  /// person goes on typing.
  final ValueChanged<String>? onSubmitted;

  @override
  State<ZestListSearchField> createState() => _ZestListSearchFieldState();
}

class _ZestListSearchFieldState extends State<ZestListSearchField> {
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onText);
  }

  @override
  void didUpdateWidget(covariant ZestListSearchField old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, widget.controller)) {
      old.controller.removeListener(_onText);
      widget.controller.addListener(_onText);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onText);
    super.dispose();
  }

  // The clear button depends on the text, which can change from outside.
  void _onText() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final hasContent = widget.controller.text.isNotEmpty;
    return Focus(
      onFocusChange: (f) => setState(() => _focused = f),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Theme.of(context).inputDecorationTheme.fillColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: _focused
                ? AppColors.v3AccentPrimary
                : ((Theme.of(context).inputDecorationTheme.enabledBorder as OutlineInputBorder?)?.borderSide.color ??
                    AppColors.v3BorderDefault),
            width: _focused ? 1.2 : 1,
          ),
        ),
        child: TextField(
          controller: widget.controller,
          focusNode: widget.focusNode,
          onChanged: widget.onChanged,
          onSubmitted: widget.onSubmitted,
          onEditingComplete: widget.onSubmitted == null ? null : () {},
          style: TextStyle(fontSize: 13, color: AppColors.v3TextPrimary),
          decoration: InputDecoration(
            filled: false,
            hintText: widget.hintText,
            hintStyle: TextStyle(fontSize: 13, color: AppColors.v3TextTertiary),
            prefixIconConstraints: const BoxConstraints(minWidth: 34, minHeight: 32),
            suffixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            prefixIcon: Icon(
              LucideIcons.search,
              size: 16,
              color: _focused
                  ? AppColors.v3AccentInk
                  : AppColors.v3TextTertiary,
            ),
            suffixIcon: hasContent
                ? IconButton(
                    tooltip: AppLocalizations.of(context)!.emptyClearSearch,
                    icon: const Icon(LucideIcons.x, size: 14),
                    color: AppColors.v3TextTertiary,
                    onPressed: () {
                      widget.controller.clear();
                      widget.onChanged('');
                    },
                  )
                : null,
            // The box above is the field's one edge: none of the theme's
            // inside it (it drew a second box).
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            disabledBorder: InputBorder.none,
            errorBorder: InputBorder.none,
            focusedErrorBorder: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
            isDense: true,
          ),
        ),
      ),
    );
  }
}
