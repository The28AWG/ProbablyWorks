import 'package:app_ui/app_ui.dart';
import 'package:material_ui/material_ui.dart';

/// Строка формы настроек: слева название и пояснение, справа поля и действия.
///
/// Так поля не стоят под заголовком с подписью: название описывает строку целиком. Действия
/// [trailing] стоят в одну линию с полем справа (иконки ключа API), а [action] — под полями,
/// прижатое к правому краю (кнопка «Сохранить» у многострочных полей). Там, где ширины меньше
/// [AppLayout.formMaxWidth], колонки складываются: название и пояснение над полями.
class SettingsFormRow extends StatelessWidget {
  const SettingsFormRow({
    required this.title,
    required this.child,
    this.description,
    this.trailing,
    this.action,
    this.crossAxisAlignment = CrossAxisAlignment.start,
    this.textBaseline,
    super.key,
  });

  final String title;

  /// Пояснение: что задаёт строка и как работают значения. Видно целиком, переносится по словам.
  /// Null — пояснения нет: строка держится на названии и полях.
  final String? description;

  /// Поле строки.
  final Widget child;

  /// Действия справа в той же линии, что и [child], центрированные по высоте поля. Нужны, когда
  /// кнопки должны занимать строку поля, а не стоять под ним, иначе высота строки зависит от их числа.
  final Widget? trailing;

  /// Действие под полями, например «Сохранить»; прижимается к правому краю.
  final Widget? action;

  /// Выравнивание заголовка и поля по поперечной оси. По умолчанию — по верхнему краю (как у полей с подписью).
  final CrossAxisAlignment crossAxisAlignment;

  /// Базовая линия для выравнивания текста, если [crossAxisAlignment] — baseline.
  final TextBaseline? textBaseline;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.titleSmall),
        if (description != null) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            description!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: child),
            if (trailing != null) ...[
              const SizedBox(width: AppSpacing.sm),
              trailing!,
            ],
          ],
        ),
        if (action != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Align(alignment: Alignment.centerRight, child: action),
        ],
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < AppLayout.formMaxWidth) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              const SizedBox(height: AppSpacing.md),
              body,
            ],
          );
        }
        return Row(
          crossAxisAlignment: crossAxisAlignment,
          textBaseline: textBaseline,
          children: [
            SizedBox(width: AppLayout.formLabelWidth, child: header),
            const SizedBox(width: AppSpacing.xl),
            Expanded(child: body),
          ],
        );
      },
    );
  }
}
