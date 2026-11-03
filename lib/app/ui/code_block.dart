import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/theme/app_colors.dart';
import 'package:probably_works/app/theme/app_theme.dart';
import 'package:probably_works/app/theme/app_tokens.dart';
import 'package:probably_works/app/ui/copy_button.dart';

/// Блок моноширинного текста: вывод команд, команды в approve, содержимое файлов.
/// Прокручивается по высоте [maxHeight], текст выделяется, кнопка копирования в углу.
class CodeBlock extends StatelessWidget {
  const CodeBlock({required this.text, this.maxHeight = 240, super.key});

  final String text;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
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
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.md,
                AppSpacing.xxl,
                AppSpacing.md,
              ),
              child: SelectableText(text, style: style),
            ),
          ),
          Positioned(
            top: AppSpacing.xs,
            right: AppSpacing.xs,
            child: CopyButton(textOf: () => text, color: colors.codeText),
          ),
        ],
      ),
    );
  }
}
