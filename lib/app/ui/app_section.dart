import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/theme/app_tokens.dart';

/// Группа полей или действий с заголовком, необязательным описанием и действием справа.
/// Заменяет разрозненные карточки в настройках и формах.
class AppSection extends StatelessWidget {
  const AppSection({
    required this.title,
    required this.children,
    this.description,
    this.trailing,
    this.gap = AppSpacing.md,
    super.key,
  });

  final String title;
  final String? description;
  final Widget? trailing;
  final List<Widget> children;
  final double gap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
            ?trailing,
          ],
        ),
        if (description != null) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            description!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        SizedBox(height: gap),
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) SizedBox(height: gap),
          children[i],
        ],
      ],
    );
  }
}
