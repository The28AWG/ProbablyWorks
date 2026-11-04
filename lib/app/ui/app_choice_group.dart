import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/theme/app_tokens.dart';

/// Вариант выбора для [AppChoiceGroup]: значение, заголовок, пояснение и необязательная иконка.
class AppChoiceOption<T> {
  const AppChoiceOption({
    required this.value,
    required this.title,
    required this.subtitle,
    this.icon,
  });

  final T value;

  /// Заголовок карточки. Занимает одну строку, лишнее обрезается многоточием.
  final String title;

  /// Пояснение: что изменится при выборе. Видно не больше двух строк; полный текст — в подсказке.
  final String subtitle;

  /// Иконка справа от заголовка; null — без иконки.
  final IconData? icon;
}

/// Выбор одного варианта карточками с радио-индикатором. Заменяет `SegmentedButton`, когда у вариантов
/// нужны пояснения: длинные подписи в сегментах не помещались бы. Карточки делят ширину поровну
/// и переносятся на узкой области. Все карточки группы имеют одинаковую высоту: заголовок в одну строку
/// и пояснение в две. Полный текст карточки показывает подсказка: заголовок жирным и пояснение ниже.
class AppChoiceGroup<T> extends StatelessWidget {
  const AppChoiceGroup({
    required this.options,
    required this.selected,
    required this.onChanged,
    super.key,
  });

  final List<AppChoiceOption<T>> options;
  final T selected;
  final ValueChanged<T> onChanged;

  /// Минимальная ширина карточки: при меньшей области вариантов становится меньше в ряд.
  static const _minCardWidth = 180.0;

  /// Размер радио-индикатора: он задаёт минимальную высоту строки заголовка.
  static const _radioSize = 20.0;

  /// Размер иконки варианта рядом с заголовком.
  static const _iconSize = 18.0;

  /// Сколько строк пояснения помещается в карточку. Больше — обрезается многоточием.
  static const _subtitleLines = 2;

  @override
  Widget build(BuildContext context) {
    final height = _cardHeight(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = AppSpacing.sm;
        // Без ограниченной ширины (например, внутри Row) делить нечего: карточки в один ряд.
        final bounded = constraints.hasBoundedWidth;
        final count = options.isEmpty ? 1 : options.length;
        final columns = bounded
            ? ((constraints.maxWidth + gap) / (_minCardWidth + gap))
                  .floor()
                  .clamp(1, count)
            : count;
        final width = bounded
            ? (constraints.maxWidth - gap * (columns - 1)) / columns
            : null;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final option in options)
              SizedBox(
                width: width,
                height: height,
                child: _ChoiceCard(
                  option: option,
                  selected: option.value == selected,
                  onTap: () => onChanged(option.value),
                ),
              ),
          ],
        );
      },
    );
  }

  /// Высота карточки: отступы, строка заголовка и [_subtitleLines] строк пояснения.
  /// Считается по метрикам шрифта и текущему масштабу текста, поэтому карточки одинаковые
  /// независимо от длины подписей. Пояснение всегда резервирует место, даже короткое.
  double _cardHeight(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);

    double lineBlockHeight(String text, TextStyle? style) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style ?? const TextStyle()),
        textDirection: direction,
        textScaler: scaler,
      )..layout();
      final result = painter.height;
      painter.dispose();
      return result;
    }

    final titleHeight = math.max(
      lineBlockHeight('Ag', textTheme.labelLarge),
      math.max(_radioSize, _iconSize),
    );
    final subtitleHeight = lineBlockHeight(
      List.filled(_subtitleLines, 'Ag').join('\n'),
      textTheme.bodySmall,
    );
    return AppSpacing.md * 2 + titleHeight + AppSpacing.xs + subtitleHeight;
  }
}

class _ChoiceCard<T> extends StatelessWidget {
  const _ChoiceCard({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final AppChoiceOption<T> option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final icon = option.icon;
    return Tooltip(
      // Подсказка показывает полный текст: заголовок жирным, пояснение на следующей строке.
      richMessage: TextSpan(
        children: [
          TextSpan(
            text: option.title,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          TextSpan(text: '\n${option.subtitle}'),
        ],
      ),
      child: Semantics(
        button: true,
        selected: selected,
        inMutuallyExclusiveGroup: true,
        child: Material(
          color: selected
              ? scheme.primaryContainer.withValues(alpha: 0.4)
              : scheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: AppRadius.lgAll,
            side: BorderSide(
              color: selected
                  ? scheme.primary
                  : scheme.outlineVariant.withValues(alpha: 0.6),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: AppChoiceGroup._radioSize,
                    color: selected ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                option.title,
                                style: theme.textTheme.labelLarge,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (icon != null) ...[
                              const SizedBox(width: AppSpacing.xs),
                              Icon(
                                icon,
                                size: AppChoiceGroup._iconSize,
                                color: scheme.onSurfaceVariant,
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          option.subtitle,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                          maxLines: AppChoiceGroup._subtitleLines,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
