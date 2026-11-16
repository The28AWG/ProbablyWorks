import 'package:material_ui/material_ui.dart';

/// Вариант выбора в [AppSelect].
class AppSelectEntry<T> {
  const AppSelectEntry({
    required this.value,
    required this.label,
    this.enabled = true,
  });

  final T value;
  final String label;
  final bool enabled;
}

/// Компактный селект для строки интерфейса: значение, стрелка и меню без ввода.
///
/// Отличается от `DropdownMenu` с подписью (формы, RULEBOOK §6): здесь нет
/// плавающей подписи и поля фильтра внутри меню, поэтому контрол читается как
/// значение настройки, а не как поле ввода. Подпись ставит владелец рядом.
///
/// Значение всегда приходит снаружи и синхронизируется с меню: `DropdownMenu`
/// обновляет текст при смене `initialSelection`, поэтому отдельный ключ не нужен.
/// Выбор доступен с клавиатуры: `Tab` ставит фокус, `Enter` открывает меню,
/// стрелки двигают подсветку.
class AppSelect<T> extends StatefulWidget {
  const AppSelect({
    required this.value,
    required this.entries,
    required this.onChanged,
    this.width,
    this.enabled = true,
    this.tooltip,
    super.key,
  });

  /// Текущее значение. Должно быть среди [entries].
  final T value;

  final List<AppSelectEntry<T>> entries;

  /// Null — выбор заблокирован: меню не открывается.
  final ValueChanged<T>? onChanged;

  /// Ширина поля. Null — на всю доступную ширину (`expandedInsets: zero`).
  final double? width;

  final bool enabled;

  /// Подсказка контрола: нужна, когда подпись рядом не помещается.
  final String? tooltip;

  @override
  State<AppSelect<T>> createState() => _AppSelectState<T>();
}

class _AppSelectState<T> extends State<AppSelect<T>> {
  late final FocusNode _focus = FocusNode(debugLabel: 'AppSelect');

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = widget.width;
    final menu = DropdownMenu<T>(
      width: width,
      expandedInsets: width == null ? EdgeInsets.zero : null,
      focusNode: _focus,
      requestFocusOnTap: false,
      enableFilter: false,
      // Только выбор: поле не редактируется, но остаётся доступным с клавиатуры.
      selectOnly: true,
      enabled: widget.enabled && widget.onChanged != null,
      initialSelection: widget.value,
      dropdownMenuEntries: [
        for (final entry in widget.entries)
          DropdownMenuEntry<T>(
            value: entry.value,
            label: entry.label,
            enabled: entry.enabled,
          ),
      ],
      onSelected: _onSelected,
    );
    final tooltip = widget.tooltip;
    return tooltip == null ? menu : Tooltip(message: tooltip, child: menu);
  }

  /// `DropdownMenu` отдаёт nullable-значение; заблокированный выбор не приходит.
  void _onSelected(T? value) {
    if (value == null) return;
    widget.onChanged?.call(value);
  }
}
