import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/theme/app_colors.dart';
import 'package:probably_works/app/theme/app_theme.dart';
import 'package:probably_works/app/theme/app_tokens.dart';

/// Цветной diff. Вход — текст, который формирует `ToolExecutor`: строки вида `+ текст`, `- текст`
/// и маркер усечения. Остальные строки показываются как контекст.
class DiffView extends StatelessWidget {
  const DiffView({required this.diff, this.maxHeight = 260, super.key});

  final String diff;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final lines = diff.split('\n');
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: AppRadius.mdAll,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          child: SelectableText.rich(
            TextSpan(
              children: [
                for (final line in lines)
                  TextSpan(text: '$line\n', style: _style(line, colors)),
              ],
            ),
            style: const TextStyle(
              fontFamily: AppTheme.monoFamily,
              fontSize: 12.5,
              height: 1.5,
            ),
          ),
        ),
      ),
    );
  }

  static TextStyle _style(String line, AppColors colors) {
    if (line.startsWith('+ ')) {
      return TextStyle(
        color: colors.diffAddText,
        backgroundColor: colors.diffAdd,
      );
    }
    if (line.startsWith('- ')) {
      return TextStyle(
        color: colors.diffRemoveText,
        backgroundColor: colors.diffRemove,
      );
    }
    return TextStyle(color: colors.muted);
  }
}
