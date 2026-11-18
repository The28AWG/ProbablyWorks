import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/shortcuts/keybinding_service.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/features/chat/presentation/widgets/composer_input.dart';
import 'package:probably_works/features/chat/presentation/widgets/mention_query.dart';
import 'package:probably_works/features/chat/presentation/widgets/mention_text_controller.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/agent/domain/workspace_entry.dart';

const _mentionRowExtent = 52.0;

/// Поле ввода с подсказками файлов workspace.
///
/// Список реагирует на `@`-токен под кареткой, а не на наличие метаданных:
/// вставленный из буфера `@app.dart` тоже можно выбрать и превратить в
/// упоминание. Выбор заменяет существующее упоминание или добавляет новое.
///
/// Подсказки живут в [OverlayPortal], как в палитре команд, а не внутри
/// карточки композера: иначе они сжимают поле, обрезаются скруглением карточки
/// и съезжают из-за разных отступов.
class MentionComposerInput extends StatefulWidget {
  const MentionComposerInput({
    required this.controller,
    required this.hint,
    required this.busy,
    required this.loading,
    required this.maxLines,
    required this.onSubmit,
    this.onFocus,
    this.search,
    this.keybindings,
    super.key,
  });

  final MentionTextController controller;
  final String hint;
  final bool busy;
  final bool loading;
  final int maxLines;
  final ValueChanged<bool> onSubmit;
  final ValueChanged<bool>? onFocus;

  /// Поиск по проекту. Null — упоминания недоступны (нет проекта).
  final Future<List<WorkspaceEntry>> Function(String query)? search;

  /// Горячая клавиша открытия списка. Null в тестах и там, где сервис
  /// клавиш не зарегистрирован: обычный набор `@` продолжает работать.
  final KeybindingService? keybindings;

  @override
  State<MentionComposerInput> createState() => _MentionComposerInputState();
}

class _MentionComposerInputState extends State<MentionComposerInput> {
  static const _debounce = Duration(milliseconds: 180);
  static const _maxPopupHeight = 300.0;

  Timer? _timer;
  MentionQuery? _token;
  MentionQuery? _dismissed;
  List<WorkspaceEntry> _suggestions = const [];
  var _selected = 0;
  var _busy = false;
  var _failed = false;
  var _generation = 0;
  var _open = false;
  late int _seenReset;

  final _portal = OverlayPortalController();
  final _scroll = ScrollController();
  final _tapGroup = Object();

  @override
  void initState() {
    super.initState();
    _seenReset = widget.controller.resetRevision;
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void didUpdateWidget(MentionComposerInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _seenReset = widget.controller.resetRevision;
      _resetState();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _onControllerChanged();
      });
    }
    if (oldWidget.search == null && widget.search != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _onControllerChanged();
      });
    }
    if (oldWidget.search != null && widget.search == null) {
      _resetState();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.controller.removeListener(_onControllerChanged);
    _scroll.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (widget.controller.resetRevision != _seenReset) {
      _seenReset = widget.controller.resetRevision;
      _dismissed = MentionQuery.at(
        widget.controller.text,
        widget.controller.selection,
      );
      _close();
      return;
    }
    final token = MentionQuery.at(
      widget.controller.text,
      widget.controller.selection,
    );
    if (token == null) {
      // Ушли из токена: следующее попадание в него снова откроет список.
      _dismissed = null;
      _close();
      return;
    }
    if (_dismissed != null && _sameToken(_dismissed!, token)) {
      _close();
      return;
    }
    if (widget.search == null) {
      _close();
      return;
    }
    final tokenChanged = _token == null || !_sameToken(_token!, token);
    _token = token;
    if (tokenChanged) {
      _selected = 0;
      _suggestions = const [];
      _failed = false;
    }
    _scheduleSearch(token, tokenChanged);
    _portal.show();
    setState(() => _open = true);
    _scrollToSelected();
  }

  void _scheduleSearch(MentionQuery token, bool tokenChanged) {
    _timer?.cancel();
    final generation = ++_generation;
    if (!tokenChanged && !_busy && _suggestions.isNotEmpty) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    final delay = token.value.isEmpty ? Duration.zero : _debounce;
    _timer = Timer(delay, () => _search(token, generation));
  }

  Future<void> _search(MentionQuery token, int generation) async {
    final search = widget.search;
    if (search == null) return;
    try {
      final result = await search(token.value);
      if (!mounted || generation != _generation) return;
      setState(() {
        _suggestions = result;
        _selected = result.isEmpty ? 0 : _selected.clamp(0, result.length - 1);
        _busy = false;
        _failed = false;
      });
      _scrollToSelected();
    } on Object {
      if (!mounted || generation != _generation) return;
      setState(() {
        _suggestions = const [];
        _busy = false;
        _failed = true;
      });
    }
  }

  void _close() {
    final wasOpen = _open;
    _resetState();
    if (wasOpen && mounted) setState(() => _open = false);
  }

  void _resetState() {
    _timer?.cancel();
    _generation++;
    _token = null;
    _suggestions = const [];
    _busy = false;
    _failed = false;
    _open = false;
    if (_portal.isShowing) _portal.hide();
  }

  void _dismiss() {
    _dismissed = _token;
    _close();
  }

  void _move(int delta) {
    if (_suggestions.isEmpty) return;
    setState(() {
      _selected = (_selected + delta).clamp(0, _suggestions.length - 1);
    });
    _scrollToSelected();
  }

  void _apply() {
    final token = _token;
    if (token == null || _suggestions.isEmpty) return;
    final entry = _suggestions[_selected.clamp(0, _suggestions.length - 1)];
    widget.controller.applySelection(token, entry);
    _dismissed = token;
    _close();
  }

  void _select(int index) => setState(() => _selected = index);

  void _applyAt(int index) {
    setState(() => _selected = index);
    _apply();
  }

  /// Держит выбранную строку в видимой части popup при навигации стрелками.
  void _scrollToSelected() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final position = _scroll.position;
      final top = _selected * _mentionRowExtent;
      final bottom = top + _mentionRowExtent;
      final current = position.pixels;
      final viewport = position.viewportDimension;
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
        _scroll.animateTo(
          clamped,
          duration: AppDurations.fast,
          curve: Curves.easeOut,
        ),
      );
    });
  }

  /// Ctrl+Space (или назначенное сочетание) открывает список заново, даже если
  /// его закрыли кликом или Esc и каретка осталась в том же токене.
  bool _openByShortcut(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final service = widget.keybindings;
    if (service == null || widget.search == null) return false;
    if (!service.bindingFor(KeybindingActions.chatMention).matches(event)) {
      return false;
    }
    final token = MentionQuery.at(
      widget.controller.text,
      widget.controller.selection,
    );
    if (token == null) return false;
    _dismissed = null;
    _onControllerChanged();
    return _open;
  }

  KeyEventResult _onKey(KeyEvent event) {
    if (_openByShortcut(event)) return KeyEventResult.handled;
    if (!_open) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _dismiss();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _move(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _move(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.tab) {
      if (_suggestions.isEmpty) return KeyEventResult.ignored;
      _apply();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => OverlayPortal.overlayChildLayoutBuilder(
    controller: _portal,
    overlayChildBuilder: _buildPopup,
    child: TapRegion(
      groupId: _tapGroup,
      child: ComposerInput(
        controller: widget.controller,
        hint: widget.hint,
        busy: widget.busy,
        loading: widget.loading,
        maxLines: widget.maxLines,
        onSubmit: widget.onSubmit,
        onFocus: widget.onFocus,
        onKeyEvent: _onKey,
      ),
    ),
  );

  /// Popup над полем: ширина ровно как у поля, высота ограничена местом до
  /// верхнего края overlay. Растёт вверх, поэтому не зависит от высоты
  /// композера и не обрезается его скруглением.
  Widget _buildPopup(BuildContext context, OverlayChildLayoutInfo info) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final origin = MatrixUtils.transformPoint(
      info.childPaintTransform,
      Offset.zero,
    );
    final bottom = info.overlaySize.height - origin.dy + AppSpacing.xs;
    final available = math.max(0.0, origin.dy - AppSpacing.md);
    return Positioned(
      left: origin.dx,
      width: info.childSize.width,
      bottom: bottom,
      child: TapRegion(
        groupId: _tapGroup,
        onTapOutside: (_) => _close(),
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
            constraints: BoxConstraints(
              maxHeight: math.min(_maxPopupHeight, available),
            ),
            child: _MentionPanel(
              suggestions: _suggestions,
              selected: _selected,
              busy: _busy,
              failed: _failed,
              controller: _scroll,
              onSelect: _select,
              onApply: _applyAt,
            ),
          ),
        ),
      ),
    );
  }

  static bool _sameToken(MentionQuery a, MentionQuery b) =>
      a.start == b.start && a.end == b.end && a.value == b.value;
}

/// Содержимое popup: список, загрузка, пусто или ошибка.
class _MentionPanel extends StatelessWidget {
  const _MentionPanel({
    required this.suggestions,
    required this.selected,
    required this.busy,
    required this.failed,
    required this.controller,
    required this.onSelect,
    required this.onApply,
  });

  final List<WorkspaceEntry> suggestions;
  final int selected;
  final bool busy;
  final bool failed;
  final ScrollController controller;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onApply;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (busy && suggestions.isEmpty) {
      return _Message(label: AppLocalizations.of(context).mentionLoading);
    }
    if (failed || suggestions.isEmpty) {
      final l10n = AppLocalizations.of(context);
      return _Message(label: failed ? l10n.mentionError : l10n.mentionEmpty);
    }
    return ListView.builder(
      controller: controller,
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      itemExtent: _mentionRowExtent,
      itemCount: suggestions.length,
      itemBuilder: (context, index) {
        final entry = suggestions[index];
        final active = index == selected;
        return _MentionTile(
          entry: entry,
          selected: active,
          onTap: () => onApply(index),
          onHover: (_) => onSelect(index),
          textColor: active ? scheme.onPrimaryContainer : scheme.onSurface,
          mutedColor: active
              ? scheme.onPrimaryContainer.withValues(alpha: 0.78)
              : scheme.onSurfaceVariant,
          selectedColor: scheme.primaryContainer,
        );
      },
    );
  }
}

/// Пустое, загрузочное и ошибочное состояние popup.
class _Message extends StatelessWidget {
  const _Message({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Text(
        label,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Одна строка popup: basename, полный путь вторым текстом.
class _MentionTile extends StatelessWidget {
  const _MentionTile({
    required this.entry,
    required this.selected,
    required this.onTap,
    required this.onHover,
    required this.textColor,
    required this.mutedColor,
    required this.selectedColor,
  });

  final WorkspaceEntry entry;
  final bool selected;
  final VoidCallback onTap;
  final ValueChanged<bool> onHover;
  final Color textColor;
  final Color mutedColor;
  final Color selectedColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = entry.path.split('/').last;
    final parent = entry.path == name
        ? ''
        : String.fromCharCodes(
            entry.path.codeUnits,
            0,
            entry.path.length - name.length,
          );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
      child: Material(
        color: selected ? selectedColor : Colors.transparent,
        borderRadius: AppRadius.smAll,
        clipBehavior: Clip.antiAlias,
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
                  entry.isDirectory
                      ? Icons.folder_outlined
                      : Icons.description_outlined,
                  size: 18,
                  color: mutedColor,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        entry.isDirectory ? '$name/' : name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: textColor,
                        ),
                      ),
                      if (parent.isNotEmpty)
                        Text(
                          parent,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: mutedColor,
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
