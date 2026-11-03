import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Кнопка копирования. Текст берёт в момент нажатия через [textOf], поэтому может стоять вне блока,
/// чей текст копирует. После копирования две секунды показывает галочку.
class CopyButton extends StatefulWidget {
  const CopyButton({
    required this.textOf,
    this.color,
    this.iconSize = 16,
    this.size,
    super.key,
  });

  final String Function() textOf;
  final Color? color;
  final double iconSize;

  /// Фиксированный квадрат кнопки. `null` — стандартный размер с отступами Material.
  final double? size;

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
    return IconButton(
      tooltip: AppLocalizations.of(context).commonCopy,
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
  }
}
