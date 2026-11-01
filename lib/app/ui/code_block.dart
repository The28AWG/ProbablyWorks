import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/theme/app_colors.dart';
import 'package:probably_works/app/theme/app_theme.dart';
import 'package:probably_works/app/theme/app_tokens.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Блок моноширинного текста: вывод команд, команды в approve, содержимое файлов.
/// Прокручивается по высоте [maxHeight], текст выделяется, кнопка копирования в углу.
class CodeBlock extends StatefulWidget {
  const CodeBlock({required this.text, this.maxHeight = 240, super.key});

  final String text;
  final double maxHeight;

  @override
  State<CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<CodeBlock> {
  var _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = context.appColors;
    final style = TextStyle(
      fontFamily: AppTheme.monoFamily,
      fontSize: 12.5,
      height: 1.5,
      color: colors.codeText,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.codeSurface,
        borderRadius: AppRadius.mdAll,
      ),
      child: Stack(
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: widget.maxHeight),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.md,
                AppSpacing.xxl,
                AppSpacing.md,
              ),
              child: SelectableText(widget.text, style: style),
            ),
          ),
          Positioned(
            top: AppSpacing.xs,
            right: AppSpacing.xs,
            child: IconButton(
              tooltip: l10n.commonCopy,
              visualDensity: VisualDensity.compact,
              color: colors.codeText,
              icon: Icon(_copied ? Icons.check : Icons.copy_outlined, size: 16),
              onPressed: _copy,
            ),
          ),
        ],
      ),
    );
  }
}
