part of 'chat_step_ledger.dart';

/// Заголовок группы шагов. Длительность не раздвигает строку: на узкой карточке она сокращается.
class _GroupHeading extends StatelessWidget {
  const _GroupHeading({
    required this.title,
    required this.titleColor,
    required this.duration,
    required this.durationColor,
    required this.accent,
    required this.icon,
    required this.expanded,
  });

  final String title;
  final Color titleColor;
  final String? duration;
  final Color durationColor;
  final Color accent;
  final IconData icon;
  final bool expanded;

  /// Иконка, зазор до заголовка, зазор до шеврона и сам шеврон. Это место длительность не занимает.
  static const _fixed = AppSpacing.sm + AppSpacing.xs + 16.0 + 18.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final durationText = duration;
    return LayoutBuilder(
      builder: (context, constraints) {
        final room = math.max(0.0, constraints.maxWidth - _fixed);
        // Длительность не забирает заголовок: ей остаётся то, что шире короткой полосы пути.
        final durationCap = math.max(0.0, room - AppSpacing.sm - 48);
        return Row(
          children: [
            Icon(icon, size: 16, color: accent),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge?.copyWith(color: titleColor),
              ),
            ),
            if (durationText != null && durationCap > 0) ...[
              const SizedBox(width: AppSpacing.sm),
              _CappedText(
                durationText,
                maxWidth: durationCap,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: durationColor,
                ),
              ),
            ],
            const SizedBox(width: AppSpacing.xs),
            AnimatedRotation(
              turns: expanded ? 0.5 : 0,
              duration: AppDurations.fast,
              curve: Curves.easeOutCubic,
              child: Icon(Icons.expand_more, size: 18, color: durationColor),
            ),
          ],
        );
      },
    );
  }
}

/// Заголовок шага: путь, счётчики строк и служебные подписи.
///
/// На широкой карточке подписи стоят справа целиком. На узкой путь сокращается первым,
/// затем подписи: их естественная ширина иначе раздвигает [Row] и рисует жёлтую полосу.
class _StepHeading extends StatelessWidget {
  const _StepHeading({
    required this.title,
    required this.color,
    required this.change,
    required this.meta,
    required this.metaColor,
    required this.background,
  });

  final String title;
  final Color color;
  final FileChange? change;
  final String? meta;
  final Color metaColor;
  final String? background;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final change = this.change;
    final added = change?.added ?? 0;
    final removed = change?.removed ?? 0;
    final titleStyle = _paintedStyle(
      context,
      const TextStyle(fontFamily: AppTheme.monoFamily, fontSize: 13),
    ).copyWith(color: color);
    final metaStyle = _paintedStyle(
      context,
      theme.textTheme.labelSmall,
    ).copyWith(color: metaColor);
    final statsStyle = _paintedStyle(context, theme.textTheme.labelSmall);
    return LayoutBuilder(
      builder: (context, constraints) => _StepHeadingBody(
        maxWidth: constraints.maxWidth,
        title: title,
        titleStyle: titleStyle,
        added: added,
        removed: removed,
        statsStyle: statsStyle,
        meta: meta,
        metaStyle: metaStyle,
        background: background,
      ),
    );
  }
}

/// Строка заголовка шага в уже известной ширине. Считает естественные ширины и не выходит за них.
class _StepHeadingBody extends StatelessWidget {
  const _StepHeadingBody({
    required this.maxWidth,
    required this.title,
    required this.titleStyle,
    required this.added,
    required this.removed,
    required this.statsStyle,
    required this.meta,
    required this.metaStyle,
    required this.background,
  });

  final double maxWidth;
  final String title;
  final TextStyle titleStyle;
  final int added;
  final int removed;
  final TextStyle statsStyle;
  final String? meta;
  final TextStyle metaStyle;
  final String? background;

  @override
  Widget build(BuildContext context) {
    final width = maxWidth;
    if (width <= 0) return const SizedBox.shrink();
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final locale = Localizations.maybeLocaleOf(context);
    final titleWidth = _textWidth(title, titleStyle, direction, scaler, locale);
    final statsWidth = _statsWidth(statsStyle, direction, scaler, locale);
    final metaText = meta;
    final metaWidth = metaText == null
        ? 0.0
        : _textWidth(metaText, metaStyle, direction, scaler, locale) +
              AppSpacing.sm;
    final backgroundText = background;
    final backgroundWidth = backgroundText == null
        ? 0.0
        : _textWidth(backgroundText, metaStyle, direction, scaler, locale) +
              AppSpacing.sm;
    final left = titleWidth + statsWidth;
    final right = metaWidth + backgroundWidth;
    // Между счётчиком строк и временем. При раскрытии кнопки съедают свободное место,
    // и без своего зазора `+N` слипается с длительностью.
    final between = statsWidth > 0 && metaText != null ? AppSpacing.sm : 0.0;
    if (left + between + right <= width) {
      return Row(
        children: [
          _CappedText(title, maxWidth: titleWidth, style: titleStyle),
          if (statsWidth > 0)
            _ChangeStats(added: added, removed: removed, style: statsStyle),
          if (between > 0) const SizedBox(width: AppSpacing.sm),
          const Spacer(),
          if (metaText != null)
            _MorphLabel(
              metaText,
              keyName: metaText,
              maxWidth: metaWidth,
              style: metaStyle,
            ),
          if (backgroundText != null)
            _MorphLabel(
              backgroundText,
              keyName: 'background',
              maxWidth: backgroundWidth,
              style: metaStyle,
            ),
        ],
      );
    }

    // Путь оставляет себе хотя бы короткую полосу, остальное отдают подписи.
    final usable = math.max(0.0, width - between);
    final titleFloor = math.min(48.0, usable);
    final rightWidth = math.min(right, math.max(0.0, usable - titleFloor));
    final leftWidth = usable - rightWidth;
    return Row(
      children: [
        _LeftCluster(
          width: leftWidth,
          title: title,
          titleStyle: titleStyle,
          added: added,
          removed: removed,
          statsStyle: statsStyle,
          statsWidth: statsWidth,
        ),
        if (between > 0 && leftWidth > 0 && rightWidth > 0)
          const SizedBox(width: AppSpacing.sm),
        if (rightWidth > 0)
          _RightCluster(
            width: rightWidth,
            meta: metaText,
            background: backgroundText,
            style: metaStyle,
          ),
      ],
    );
  }

  double _statsWidth(
    TextStyle style,
    TextDirection direction,
    TextScaler scaler,
    Locale? locale,
  ) {
    var width = 0.0;
    if (added > 0) {
      width +=
          AppSpacing.sm +
          _textWidth('+$added', style, direction, scaler, locale);
    }
    if (removed > 0) {
      width +=
          AppSpacing.sm +
          _textWidth('-$removed', style, direction, scaler, locale);
    }
    return width;
  }
}

/// Левая часть шапки, когда всё вместе не помещается: путь сокращается, счётчики живут на остатке.
class _LeftCluster extends StatelessWidget {
  const _LeftCluster({
    required this.width,
    required this.title,
    required this.titleStyle,
    required this.added,
    required this.removed,
    required this.statsStyle,
    required this.statsWidth,
  });

  final double width;
  final String title;
  final TextStyle titleStyle;
  final int added;
  final int removed;
  final TextStyle statsStyle;
  final double statsWidth;

  @override
  Widget build(BuildContext context) {
    if (width <= 0) return const SizedBox.shrink();
    final badges = statsWidth;
    if (badges > 0 && badges <= width) {
      return SizedBox(
        width: width,
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: titleStyle,
              ),
            ),
            if (statsWidth > 0)
              _ChangeStats(added: added, removed: removed, style: statsStyle),
          ],
        ),
      );
    }
    // Счётчики не помещаются целиком: путь оставляет им до 62% строки, текст сокращается.
    final badgeSlice = math.min(badges, width * 0.62);
    if (badgeSlice < 12) {
      return SizedBox(
        width: width,
        child: Text(
          title,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: titleStyle,
        ),
      );
    }
    final colors = context.appColors;
    return SizedBox(
      width: width,
      child: Row(
        children: [
          SizedBox(
            width: width - badgeSlice,
            child: Text(
              title,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: titleStyle,
            ),
          ),
          SizedBox(
            width: badgeSlice,
            child: Row(
              children: [
                if (added > 0)
                  Flexible(
                    child: Text(
                      '+$added',
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: statsStyle.copyWith(color: colors.diffAddText),
                    ),
                  ),
                if (removed > 0)
                  Flexible(
                    child: Text(
                      '-$removed',
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: statsStyle.copyWith(color: colors.diffRemoveText),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Подписи справа от пути. В тесноте делят остаток и сокращаются, а не раздвигают шапку.
class _RightCluster extends StatelessWidget {
  const _RightCluster({
    required this.width,
    required this.meta,
    required this.background,
    required this.style,
  });

  final double width;
  final String? meta;
  final String? background;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final metaText = meta;
    final backgroundText = background;
    return SizedBox(
      width: width,
      child: Row(
        children: [
          if (metaText != null)
            Flexible(
              child: _MorphLabel(metaText, keyName: metaText, style: style),
            ),
          if (backgroundText != null)
            Flexible(
              child: _MorphLabel(
                backgroundText,
                keyName: 'background',
                style: style,
              ),
            ),
        ],
      ),
    );
  }
}

/// Подпись, которая проявляется и сжимается вместе со сменой текста.
class _MorphLabel extends StatelessWidget {
  const _MorphLabel(
    this.text, {
    required this.keyName,
    required this.style,
    this.maxWidth,
  });

  final String text;
  final String keyName;
  final TextStyle style;
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final cap = maxWidth;
    final label = Text(
      key: ValueKey(keyName),
      text,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
    if (cap == null) return ChatMorph(child: label);
    return ChatMorph(
      child: Row(
        key: ValueKey(keyName),
        mainAxisSize: MainAxisSize.min,
        children: [
          _CappedText(
            text,
            maxWidth: math.max(0, cap - AppSpacing.sm),
            style: style,
          ),
          const SizedBox(width: AppSpacing.sm),
        ],
      ),
    );
  }
}

/// Текст не шире [maxWidth]. Зазор слева входит в бюджет родителя, но не в потолок самого текста.
class _CappedText extends StatelessWidget {
  const _CappedText(
    this.text, {
    required this.maxWidth,
    required this.style,
    this.leading = 0,
  });

  final String text;
  final double maxWidth;
  final TextStyle? style;
  final double leading;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (leading > 0) SizedBox(width: leading),
      ConstrainedBox(
        constraints: BoxConstraints(maxWidth: math.max(0, maxWidth)),
        child: Text(
          text,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: style,
        ),
      ),
    ],
  );
}

/// Стиль, которым [Text] реально рисует строку: с масштабом и интервалом темы.
///
/// Незаданные поля стиля не сбрасывают интервал родителя, поэтому ширина считается
/// по уже склеенному стилю. Иначе бюджет колонки короче нарисованного текста.
TextStyle _paintedStyle(BuildContext context, TextStyle? style) {
  final base = DefaultTextStyle.of(context).style;
  final merged = style == null || style.inherit ? base.merge(style) : style;
  return merged.copyWith(inherit: false);
}

double _textWidth(
  String text,
  TextStyle style,
  TextDirection direction,
  TextScaler scaler,
  Locale? locale,
) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: direction,
    textScaler: scaler,
    locale: locale,
    maxLines: 1,
  )..layout();
  final width = painter.width.ceilToDouble();
  painter.dispose();
  return width;
}

/// Счётчики `+N` и `-M` в цветах diff. Нулевой счётчик не показывается.
///
/// Каждый счётчик ограничен своей измеренной шириной: иначе длинный `+N` рядом с коротким `-M`
/// делился бы поровну и обрезался даже там, где места хватает.
class _ChangeStats extends StatelessWidget {
  const _ChangeStats({
    required this.added,
    required this.removed,
    required this.style,
  });

  final int added;
  final int removed;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    if (added == 0 && removed == 0) return const SizedBox.shrink();
    final colors = context.appColors;
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final locale = Localizations.maybeLocaleOf(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (added > 0)
          _CappedText(
            '+$added',
            maxWidth: _textWidth('+$added', style, direction, scaler, locale),
            style: style.copyWith(color: colors.diffAddText),
            leading: AppSpacing.sm,
          ),
        if (removed > 0)
          _CappedText(
            '-$removed',
            maxWidth: _textWidth('-$removed', style, direction, scaler, locale),
            style: style.copyWith(color: colors.diffRemoveText),
            leading: AppSpacing.sm,
          ),
      ],
    );
  }
}
