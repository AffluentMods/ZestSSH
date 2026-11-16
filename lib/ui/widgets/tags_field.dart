import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zestssh/database/daos/connection_tags_dao.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';

/// A token-style multi-tag editor.
///
/// Two-row layout: existing chips wrap-flow at the top, full-width
/// input below. The input:
/// - commits a tag on Enter, comma, or when focus is lost
/// - autocompletes from [availableTags] (with already-applied tags
///   filtered out so the user can't pick the same tag twice)
/// - canonicalises with [ConnectionTagsDao.normalize] before adding
///
/// Stateless w.r.t. the canonical tag list - the parent owns it via
/// [onChanged]. The widget tracks only the in-progress text input.
class TagsField extends StatefulWidget {
  const TagsField({
    super.key,
    required this.tags,
    required this.onChanged,
    this.availableTags = const [],
    this.label,
    this.hintText,
  });

  /// The current tag set (canonical form). Renders as chips.
  final List<String> tags;

  /// Called whenever the tag set changes (chip removed, tag added).
  /// Receives the new canonical-form list.
  final ValueChanged<List<String>> onChanged;

  /// Source for autocomplete suggestions. Already-applied tags are
  /// filtered out automatically.
  final List<String> availableTags;

  /// Field label shown above the editor (e.g. "Tags").
  final String? label;

  /// Hint text inside the input when empty.
  final String? hintText;

  @override
  State<TagsField> createState() => _TagsFieldState();
}

class _TagsFieldState extends State<TagsField> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocusChange);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    // Commit any in-flight text when focus leaves so the user doesn't
    // lose their typing on save.
    if (!_focusNode.hasFocus) {
      _commit(_controller.text);
    }
    setState(() {}); // repaint border on focus change
  }

  void _commit(String raw) {
    final canonical = ConnectionTagsDao.normalize(raw);
    if (canonical == null) {
      _controller.clear();
      return;
    }
    if (widget.tags.contains(canonical)) {
      _controller.clear();
      return;
    }
    final updated = [...widget.tags, canonical]..sort();
    widget.onChanged(updated);
    _controller.clear();
  }

  void _remove(String tag) {
    final updated = widget.tags.where((t) => t != tag).toList();
    widget.onChanged(updated);
  }

  @override
  Widget build(BuildContext context) {
    final suggestions = widget.availableTags
        .where((t) => !widget.tags.contains(t))
        .toList(growable: false);

    final focused = _focusNode.hasFocus;
    final borderColor = focused
        ? AppColors.orange.withValues(alpha: 0.6)
        : AppColors.divider;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.label != null) ...[
          Text(
            widget.label!,
            style: TextStyle(
              color: AppColors.onSurfaceVariant,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
        ],
        AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
          decoration: BoxDecoration(
            color: AppColors.surfaceDark,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: borderColor,
              width: focused ? 1.2 : 0.6,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.tags.isNotEmpty) ...[
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final tag in widget.tags)
                      _TagChip(
                        label: tag,
                        onDelete: () => _remove(tag),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
              // Full-width input row. RawAutocomplete drives
              // suggestion popup; the field underneath is bare so the
              // user gets the entire row width to type in.
              RawAutocomplete<String>(
                textEditingController: _controller,
                focusNode: _focusNode,
                optionsBuilder: (textEditingValue) {
                  final query = textEditingValue.text.trim().toLowerCase();
                  if (query.isEmpty) return suggestions;
                  return suggestions
                      .where((s) => s.contains(query))
                      .toList();
                },
                onSelected: _commit,
                fieldViewBuilder: (
                  context,
                  controller,
                  focusNode,
                  onFieldSubmitted,
                ) {
                  // Backspace on an empty input deletes the last chip - same
                  // removal path as the per-chip x. Purely an event
                  // interceptor: it neither takes focus nor a traversal stop,
                  // so normal backspace (when text is present) is untouched.
                  return Focus(
                    canRequestFocus: false,
                    skipTraversal: true,
                    onKeyEvent: (node, event) {
                      if (event is KeyDownEvent &&
                          event.logicalKey == LogicalKeyboardKey.backspace &&
                          controller.text.isEmpty &&
                          widget.tags.isNotEmpty) {
                        _remove(widget.tags.last);
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    child: TextField(
                    controller: controller,
                    focusNode: focusNode,
                    maxLength: ConnectionTagsDao.maxLength,
                    decoration: InputDecoration(
                      isDense: true,
                      filled: false,
                      border: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      errorBorder: InputBorder.none,
                      focusedErrorBorder: InputBorder.none,
                      counterText: '',
                      hintText: widget.tags.isEmpty
                          ? (widget.hintText ?? gl10n.tagsFieldAdd)
                          : gl10n.tagsFieldAddAnother,
                      hintStyle: TextStyle(
                        color: AppColors.onSurfaceDim,
                        fontSize: 13,
                      ),
                      contentPadding:
                          const EdgeInsets.symmetric(vertical: 4),
                    ),
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.onSurface,
                    ),
                    // Commit on comma without inserting it - feels
                    // natural to power users coming from any chip
                    // input ever made.
                    inputFormatters: [
                      TextInputFormatter.withFunction((oldValue, newValue) {
                        if (newValue.text.endsWith(',')) {
                          final candidate = newValue.text
                              .substring(0, newValue.text.length - 1);
                          WidgetsBinding.instance
                              .addPostFrameCallback((_) {
                            if (!mounted) return;
                            _commit(candidate);
                          });
                          return TextEditingValue(
                            text: candidate,
                            selection: TextSelection.collapsed(
                              offset: candidate.length,
                            ),
                          );
                        }
                        return newValue;
                      }),
                    ],
                    onSubmitted: (value) {
                      _commit(value);
                      focusNode.requestFocus();
                    },
                    ),
                  );
                },
                optionsViewBuilder: (context, onSelected, options) {
                  return Align(
                    alignment: Alignment.topLeft,
                    child: Material(
                      color: AppColors.surfaceContainerHigh,
                      elevation: 4,
                      borderRadius: BorderRadius.circular(8),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxHeight: 200,
                          maxWidth: 320,
                        ),
                        child: ListView.builder(
                          shrinkWrap: true,
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          itemCount: options.length,
                          itemBuilder: (context, index) {
                            final opt = options.elementAt(index);
                            return InkWell(
                              onTap: () => onSelected(opt),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                child: Text(
                                  opt,
                                  style: TextStyle(
                                    color: AppColors.onSurface,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TagChip extends StatelessWidget {
  const _TagChip({required this.label, required this.onDelete});
  final String label;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppColors.divider,
          width: 0.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              color: AppColors.onSurface,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 4),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Tooltip(message: AppLocalizations.of(context)!.commonRemove, child: GestureDetector(
              onTap: onDelete,
              child: Container(
                width: 18,
                height: 18,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.surfaceLight,
                ),
                child: Icon(
                  LucideIcons.x,
                  size: 12,
                  color: AppColors.onSurfaceDim,
                ),
              ),
            )),
          ),
        ],
      ),
    );
  }
}
