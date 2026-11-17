import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Кнопка копирования. Текст берёт в момент нажатия через [textOf], поэтому может стоять вне блока,
/// чей текст копирует. После копирования две секунды показывает галочку.
/// [richTooltip] заменяет стандартную подсказку: например, название действия и
/// значение в две строки, где значение выделено моноширинным стилем.
class CopyButton extends StatefulWidget {
  const CopyButton({
    required this.textOf,
    this.color,
    this.iconSize = 16,
    this.size,
    this.tooltip,
    this.richTooltip,
    this.focusNode,
    super.key,
  });

  final String Function() textOf;
  final Color? color;
  final double iconSize;

  /// Фиксированный квадрат кнопки. `null` — стандартный размер с отступами Material.
  final double? size;

  /// Подпись подсказки. Null — «Копировать» из словаря.
  final String? tooltip;

  /// Подсказка с разметкой: например, название действия и значение в две строки.
  /// Взаимоисключающа с [tooltip].
  final InlineSpan? richTooltip;

  /// Фокус кнопки. Нужен владельцу, который показывает её по фокусу с клавиатуры.
  final FocusNode? focusNode;

  @override
  State<CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<CopyButton> {
  var _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.textOf()));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final richTooltip = widget.richTooltip;
    final button = IconButton(
      // Rich-подсказка сама заменяет стандартную: два Tooltip друг над другом не нужны.
      tooltip: richTooltip == null
          ? (widget.tooltip ?? AppLocalizations.of(context).commonCopy)
          : null,
      focusNode: widget.focusNode,
      visualDensity: VisualDensity.compact,
      padding: size == null ? null : EdgeInsets.zero,
      constraints: size == null
          ? null
          : BoxConstraints.tightFor(width: size, height: size),
      color: widget.color,
      icon: Icon(
        _copied ? Icons.check : Icons.copy_outlined,
        size: widget.iconSize,
      ),
      onPressed: _copy,
    );
    if (richTooltip == null) return button;
    return Tooltip(
      richMessage: richTooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: button,
    );
  }
}
