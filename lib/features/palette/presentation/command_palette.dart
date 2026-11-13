import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/features/palette/domain/palette_command.dart';
import 'package:probably_works/features/palette/presentation/palette_controller.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/agent/domain/search.dart';

/// Модальное окно единой палитры: поиск, фильтры, команды и чаты.
class CommandPaletteDialog extends StatefulWidget {
  const CommandPaletteDialog({
    required this.controller,
    required this.onCommand,
    required this.onHit,
    required this.onClose,
    super.key,
  });

  final PaletteController controller;
  final ValueChanged<PaletteCommand> onCommand;
  final ValueChanged<SearchHit> onHit;
  final VoidCallback onClose;

  @override
  State<CommandPaletteDialog> createState() => _CommandPaletteDialogState();
}

class _CommandPaletteDialogState extends State<CommandPaletteDialog> {
  static const _rowExtent = 62.0;
  static const _suggestionRowExtent = 54.0;

  late final TextEditingController _input;
  late final FocusNode _focus;
  final _scroll = ScrollController();
  final _suggestionScroll = ScrollController();

  final _suggestionsPortal = OverlayPortalController();

  /// Общая группа для поля и подсказок: тап по полю не считается «вне списка».
  final _suggestionTapGroup = Object();

  var _lastSelected = 0;
  var _suggestionIndex = 0;
  var _suggestionSignature = '';

  PaletteController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _input = TextEditingController(text: _controller.raw);
    _focus = FocusNode(onKeyEvent: _onKey);
    _controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    _suggestionScroll.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (_input.text != _controller.raw) {
      _input.value = TextEditingValue(
        text: _controller.raw,
        selection: TextSelection.collapsed(offset: _controller.raw.length),
      );
    }
    final suggestions = _controller.suggestions;
    final signature = _controller.autocompleteActive
        ? suggestions.map((item) => item.replacement).join('\u0000')
        : '';
    if (signature != _suggestionSignature) {
      _suggestionSignature = signature;
      _suggestionIndex = 0;
    }
    final showSuggestions =
        _controller.autocompleteActive && suggestions.isNotEmpty;
    if (showSuggestions && !_suggestionsPortal.isShowing) {
      _suggestionsPortal.show();
    } else if (!showSuggestions && _suggestionsPortal.isShowing) {
      _suggestionsPortal.hide();
    }
    final changed = _lastSelected != _controller.selected;
    if (changed) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToSelected());
    }
    setState(() => _lastSelected = _controller.selected);
  }

  void _scrollToSelected() {
    _keepRowVisible(_scroll, _controller.selected, _rowExtent);
  }

  /// Держит выбранную строку в видимой части списка. Верхняя граница
  /// учитывает padding списка: иначе последняя строка обрезается на его
  /// высоту, а clamp по maxScrollExtent не должен попадать в расчёт нижней
  /// границы — из-за этого конец списка раньше не показывался.
  static void _keepRowVisible(
    ScrollController controller,
    int index,
    double extent, {
    double leading = 0,
  }) {
    if (!controller.hasClients) return;
    final position = controller.position;
    final current = controller.offset;
    final viewport = position.viewportDimension;
    final top = leading + index * extent;
    final bottom = top + extent;
    double? target;
    if (top < current) {
      target = top;
    } else if (bottom > current + viewport) {
      target = bottom - viewport;
    }
    if (target == null) return;
    final clamped = target.clamp(0.0, position.maxScrollExtent);
    if ((clamped - current).abs() < 0.5) return;
    unawaited(
      controller.animateTo(
        clamped,
        duration: AppDurations.fast,
        curve: Curves.easeOut,
      ),
    );
  }

  void _moveSuggestion(int delta) {
    final count = _controller.suggestions.length;
    if (count == 0) return;
    setState(() {
      _suggestionIndex = (_suggestionIndex + delta).clamp(0, count - 1);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToSuggestion());
  }

  void _scrollToSuggestion() {
    _keepRowVisible(
      _suggestionScroll,
      _suggestionIndex,
      _suggestionRowExtent,
      leading: AppSpacing.xs,
    );
  }

  void _applySuggestion(PaletteSuggestion suggestion) {
    _controller.applySuggestion(suggestion);
    _focus.requestFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (_controller.autocompleteActive) {
      final suggestions = _controller.suggestions;
      if (key == LogicalKeyboardKey.arrowDown && suggestions.isNotEmpty) {
        _moveSuggestion(1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp && suggestions.isNotEmpty) {
        _moveSuggestion(-1);
        return KeyEventResult.handled;
      }
      if ((key == LogicalKeyboardKey.enter ||
              key == LogicalKeyboardKey.numpadEnter ||
              key == LogicalKeyboardKey.tab) &&
          suggestions.isNotEmpty) {
        _applySuggestion(suggestions[_suggestionIndex]);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.escape) {
        _controller.dismissAutocomplete();
        return KeyEventResult.handled;
      }
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _controller.moveSelection(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _controller.moveSelection(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _activate();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (_controller.canGoBack) {
        _controller.goBack();
      } else {
        widget.onClose();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _activate() {
    final result = _controller.selectedResult;
    if (result == null) return;
    if (result.kind == PaletteResultKind.back) {
      _controller.goBack();
      return;
    }
    if (result.isGroup && result.command != null) {
      _controller.enterGroup(result.command!);
      return;
    }
    if (result.command != null) {
      widget.onCommand(result.command!);
      return;
    }
    if (result.hit != null) widget.onHit(result.hit!);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.xxl,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: AppLayout.formMaxWidth,
          maxHeight: size.height * 0.72,
        ),
        child: AppCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.lg,
                  AppSpacing.lg,
                  AppSpacing.sm,
                ),
                child: OverlayPortal.overlayChildLayoutBuilder(
                  controller: _suggestionsPortal,
                  overlayChildBuilder: _buildSuggestions,
                  child: TapRegion(
                    groupId: _suggestionTapGroup,
                    child: AppTextField(
                      controller: _input,
                      focusNode: _focus,
                      autofocus: true,
                      hint: l10n.paletteSearchHint,
                      prefixIcon: Icons.search,
                      onChanged: _onSearchChanged,
                    ),
                  ),
                ),
              ),
              if (_controller.loading)
                const Padding(
                  padding: EdgeInsets.only(top: AppSpacing.sm),
                  child: LinearProgressIndicator(minHeight: 2),
                ),
              const SizedBox(height: AppSpacing.sm),
              Expanded(
                child: _controller.results.isEmpty
                    ? Center(
                        child: Text(
                          _controller.loading
                              ? l10n.paletteLoading
                              : l10n.paletteNoResults,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                      )
                    : ListView.builder(
                        controller: _scroll,
                        itemExtent: _rowExtent,
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm,
                        ),
                        itemCount: _controller.results.length,
                        itemBuilder: (context, index) => _ResultTile(
                          result: _controller.results[index],
                          selected:
                              index == _controller.selected &&
                              _controller.selectionVisible,
                          onTap: () => _onTapResult(index),
                          onHover: (_) => _controller.selectIndex(index),
                          typeLabel: _typeLabel(
                            l10n,
                            _controller.results[index],
                          ),
                        ),
                      ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: AppSpacing.sm,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.paletteKeyboardHint,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Text(
                      '@command · @project · @current',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _onSearchChanged(String value) {
    final caret = _input.selection.baseOffset;
    _controller.setRaw(value, caretOffset: caret < 0 ? value.length : caret);
  }

  void _onSuggestionTapOutside(PointerDownEvent event) {
    if (_controller.autocompleteActive) _controller.dismissAutocomplete();
  }

  void _onSuggestionHover(int index, bool hovered) {
    if (!hovered || _suggestionIndex == index) return;
    setState(() => _suggestionIndex = index);
  }

  void _onTapResult(int index) {
    _controller.selectIndex(index);
    _activate();
  }

  /// Выпадающий список подсказок. Это не `PopupMenu` и не `DropdownButton`:
  /// обычный `OverlayPortal` с `CompositedTransformFollower`, поэтому ширина
  /// ровно как у поля, длинный текст обрезается, а список скроллится.
  Widget _buildSuggestions(BuildContext context, OverlayChildLayoutInfo info) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final suggestions = _controller.suggestions;
    final origin = MatrixUtils.transformPoint(
      info.childPaintTransform,
      Offset.zero,
    );
    final top = origin.dy + info.childSize.height + AppSpacing.xs;
    final available = math.max(
      0.0,
      info.overlaySize.height - top - AppSpacing.md,
    );
    return Positioned(
      left: origin.dx,
      top: top,
      width: info.childSize.width,
      child: TapRegion(
        groupId: _suggestionTapGroup,
        onTapOutside: _onSuggestionTapOutside,
        child: Material(
          color: scheme.surfaceContainerHigh,
          elevation: 8,
          shadowColor: scheme.shadow.withValues(alpha: 0.3),
          shape: RoundedRectangleBorder(
            borderRadius: AppRadius.mdAll,
            side: BorderSide(color: scheme.outlineVariant),
          ),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: math.min(300.0, available)),
            child: ListView.builder(
              controller: _suggestionScroll,
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
              itemExtent: _suggestionRowExtent,
              itemCount: suggestions.length,
              itemBuilder: (context, index) {
                final suggestion = suggestions[index];
                return _SuggestionTile(
                  suggestion: suggestion,
                  selected: index == _suggestionIndex,
                  onTap: () => _applySuggestion(suggestion),
                  onHover: (hovered) => _onSuggestionHover(index, hovered),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  String _typeLabel(AppLocalizations l10n, PaletteResult result) =>
      switch (result.kind) {
        PaletteResultKind.command => l10n.paletteTypeCommand,
        PaletteResultKind.chat => l10n.paletteTypeChat,
        PaletteResultKind.message => l10n.paletteTypeMessage,
        PaletteResultKind.suggestion => l10n.paletteTypeFilter,
        PaletteResultKind.back => '',
      };
}

class _SuggestionTile extends StatelessWidget {
  const _SuggestionTile({
    required this.suggestion,
    required this.selected,
    required this.onTap,
    required this.onHover,
  });

  final PaletteSuggestion suggestion;
  final bool selected;
  final VoidCallback onTap;
  final ValueChanged<bool> onHover;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tooltip = suggestion.subtitle == null
        ? suggestion.title
        : '${suggestion.title}\n${suggestion.subtitle}';
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xs,
        vertical: 2,
      ),
      child: Material(
        color: selected ? scheme.surfaceContainerHighest : Colors.transparent,
        borderRadius: AppRadius.smAll,
        child: InkWell(
          onTap: onTap,
          onHover: onHover,
          borderRadius: AppRadius.smAll,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: AppSpacing.xs,
            ),
            child: Row(
              children: [
                Icon(
                  suggestion.icon ?? Icons.filter_alt_outlined,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Tooltip(
                        message: tooltip,
                        child: Text(
                          suggestion.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                      if (suggestion.subtitle != null)
                        Tooltip(
                          message: tooltip,
                          child: Text(
                            suggestion.subtitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({
    required this.result,
    required this.selected,
    required this.onTap,
    required this.onHover,
    required this.typeLabel,
  });

  final PaletteResult result;
  final bool selected;
  final VoidCallback onTap;
  final ValueChanged<bool> onHover;
  final String typeLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final title = result.kind == PaletteResultKind.back
        ? AppLocalizations.of(context).paletteBack
        : result.title;
    final icon =
        result.icon ??
        switch (result.kind) {
          PaletteResultKind.command => Icons.bolt_outlined,
          PaletteResultKind.chat => Icons.chat_bubble_outline,
          PaletteResultKind.message => Icons.subject,
          PaletteResultKind.suggestion => Icons.filter_alt_outlined,
          PaletteResultKind.back => Icons.arrow_back,
        };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selected ? scheme.surfaceContainerHighest : Colors.transparent,
        borderRadius: AppRadius.mdAll,
        child: InkWell(
          onTap: onTap,
          onHover: onHover,
          borderRadius: AppRadius.mdAll,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: Row(
              children: [
                Icon(icon, size: 20, color: scheme.onSurfaceVariant),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                      if (result.subtitle != null &&
                          result.subtitle!.trim().isNotEmpty)
                        Text(
                          result.subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                if (result.isGroup)
                  Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  )
                else if (typeLabel.isNotEmpty)
                  Text(
                    typeLabel,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
