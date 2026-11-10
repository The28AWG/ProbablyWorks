import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/theme/app_tokens.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_motion.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Вид блока журнала: группа шагов, рассуждение или команда. От него зависит оформление тела.
enum StepKind { group, thought, command }

/// Цвета строки блока: основной текст, приглушённый текст и акцент статуса.
class StepPalette {
  const StepPalette({
    required this.text,
    required this.muted,
    required this.accent,
  });

  final Color text;
  final Color muted;
  final Color accent;
}

/// Блок журнала шагов в виде карточки: заголовок, по которому блок раскрывается, и раскрываемое тело.
///
/// Подсветка при наведении охватывает весь блок, а не только заголовок, поэтому совпадает с видимой
/// границей карточки. Группа шагов — внешняя карточка, а строки внутри неё подсвечиваются по отдельности.
class StepBlock extends StatefulWidget {
  const StepBlock({
    required this.kind,
    required this.accent,
    required this.expanded,
    required this.header,
    required this.body,
    this.inGroup = false,
    this.showHeader = true,
    this.onToggle,
    this.canFullHeight = false,
    this.trailing,
    super.key,
  });

  final StepKind kind;

  /// Цвет статуса: иконка заголовка.
  final Color accent;

  /// Тело раскрыто.
  final bool expanded;

  /// Блок стоит внутри группы: своей рамки у него нет, остаётся подсветка строки.
  final bool inGroup;

  /// Заголовок виден. Для группы из одного шага заголовок скрыт, блок выглядит как обычная строка.
  final bool showHeader;

  /// Нажатие на заголовок. `null` — заголовок не раскрывается.
  final VoidCallback? onToggle;

  /// Показать кнопку «на всю высоту», когда тело раскрыто.
  final bool canFullHeight;

  /// Действия в заголовке, пока тело раскрыто: стоят левее кнопки «на всю высоту».
  final Widget Function(StepPalette palette)? trailing;

  /// Содержимое заголовка, без отступов и кнопки «на всю высоту».
  final Widget Function(StepPalette palette) header;

  /// Тело. [fullHeight] — пользователь снял ограничение высоты.
  final Widget Function(StepPalette palette, bool fullHeight) body;

  @override
  State<StepBlock> createState() => _StepBlockState();
}

class _StepBlockState extends State<StepBlock> {
  var _hovered = false;
  var _fullHeight = false;

  bool get _isGroup => widget.kind == StepKind.group;

  /// Группа подсветки при наведении не получает: подсвечиваются строки внутри неё.
  bool get _hoverable => !_isGroup;

  void _toggle() {
    widget.onToggle?.call();
  }

  void _toggleFullHeight() {
    setState(() => _fullHeight = !_fullHeight);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = StepPalette(
      text: scheme.onSurface,
      muted: scheme.onSurfaceVariant,
      accent: widget.accent,
    );
    final hovered = _hovered && _hoverable;
    final radius = _radius;
    final outline = _outline(scheme, hovered);

    final headerRow = InkWell(
      borderRadius: radius,
      // Подсветку при наведении рисует карточка целиком, поэтому заголовок её не рисует.
      hoverColor: Colors.transparent,
      onTap: widget.onToggle == null ? null : _toggle,
      child: _StepHeader(
        padding: _headerPadding,
        palette: palette,
        header: widget.header,
        trailing: widget.expanded ? widget.trailing?.call(palette) : null,
        showFullButton: widget.canFullHeight && widget.expanded,
        fullHeight: _fullHeight,
        onToggleFullHeight: _toggleFullHeight,
      ),
    );
    final inner = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_isGroup)
          ChatReveal(open: widget.showHeader, child: headerRow)
        else
          headerRow,
        ChatReveal(
          open: widget.expanded,
          child: _StepBody(
            kind: widget.kind,
            inGroup: widget.inGroup,
            grouped: widget.showHeader,
            child: widget.body(palette, _fullHeight),
          ),
        ),
      ],
    );

    return MouseRegion(
      onEnter: _hoverable ? (_) => setState(() => _hovered = true) : null,
      onExit: _hoverable ? (_) => setState(() => _hovered = false) : null,
      child: AnimatedContainer(
        duration: AppDurations.fast,
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: _fill(scheme, hovered),
          borderRadius: radius,
        ),
        // Рамка поверх содержимого: иначе тёмная подложка команды закрывает её по краю.
        // Рамка задана всегда (прозрачная, если не нужна): иначе смена группы и одиночного шага
        // меняет структуру дерева и пересоздаёт содержимое вместе с состоянием строк.
        foregroundDecoration: BoxDecoration(
          borderRadius: radius,
          border: Border.all(color: outline ?? Colors.transparent),
        ),
        child: ClipRRect(borderRadius: radius, child: inner),
      ),
    );
  }

  EdgeInsets get _headerPadding => _isGroup || !widget.inGroup
      ? const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        )
      : const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xs,
        );

  BorderRadius get _radius =>
      !_isGroup && widget.inGroup ? AppRadius.smAll : AppRadius.mdAll;

  Color? _fill(ColorScheme scheme, bool hovered) {
    if (_isGroup) return widget.showHeader ? scheme.surfaceContainerLow : null;
    if (widget.inGroup) return hovered ? scheme.surfaceContainerHigh : null;
    return hovered ? scheme.surfaceContainer : scheme.surfaceContainerLow;
  }

  Color? _outline(ColorScheme scheme, bool hovered) {
    if (_isGroup) return widget.showHeader ? scheme.outlineVariant : null;
    if (widget.inGroup) return null;
    return hovered ? scheme.outline : scheme.outlineVariant;
  }
}

/// Заголовок блока: содержимое из [header] и кнопка «на всю высоту», когда тело раскрыто.
class _StepHeader extends StatelessWidget {
  const _StepHeader({
    required this.padding,
    required this.palette,
    required this.header,
    required this.trailing,
    required this.showFullButton,
    required this.fullHeight,
    required this.onToggleFullHeight,
  });

  final EdgeInsets padding;
  final StepPalette palette;
  final Widget Function(StepPalette palette) header;
  final Widget? trailing;
  final bool showFullButton;
  final bool fullHeight;
  final VoidCallback onToggleFullHeight;

  /// Квадрат кнопки действий. Кнопки стоят поверх заголовка справа, а не в строке, поэтому их появление
  /// при раскрытии не меняет высоту заголовка: текст и шеврон остаются на месте.
  static const _actionSize = 24.0;

  /// Иконка статуса, зазор и шеврон. Этот кусок строки не отдаём кнопкам: иначе на узкой карточке
  /// резерв кнопок шире остатка и строка переполняется.
  static const _statusWidth = AppSpacing.sm + 16.0 + 18.0;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final actions = [
      ?trailing,
      if (showFullButton)
        IconButton(
          key: const ValueKey('step-full-height'),
          tooltip: fullHeight ? l10n.runCollapseFull : l10n.runExpandFull,
          padding: EdgeInsets.zero,
          iconSize: 18,
          color: palette.muted,
          icon: Icon(fullHeight ? Icons.fullscreen_exit : Icons.fullscreen),
          onPressed: onToggleFullHeight,
        ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final wanted = actions.length * _actionSize;
        final room = math.max(
          0.0,
          constraints.maxWidth - padding.horizontal - _statusWidth,
        );
        // Место под кнопки резервируем справа, чтобы текст заголовка не лез под них.
        // На узкой карточке резерв не забирает иконку и шеврон: кнопки тогда уменьшаются.
        final actionsWidth = math.min(wanted.toDouble(), room);
        return Stack(
          children: [
            Padding(
              padding: EdgeInsets.only(
                left: padding.left,
                top: padding.top,
                right: padding.right + actionsWidth,
                bottom: padding.bottom,
              ),
              child: header(palette),
            ),
            Positioned.fill(
              child: Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: EdgeInsets.only(right: padding.right),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final action in actions)
                          SizedBox.square(
                            dimension: _actionSize,
                            child: action,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Отступы тела карточки. Тело команды вне группы идёт вровень с рамкой: у неё своя подложка.
class _StepBody extends StatelessWidget {
  const _StepBody({
    required this.kind,
    required this.inGroup,
    required this.grouped,
    required this.child,
  });

  final StepKind kind;
  final bool inGroup;

  /// Для группы: заголовок виден, то есть группа из нескольких шагов.
  final bool grouped;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedPadding(
    duration: AppDurations.fast,
    curve: Curves.easeOutCubic,
    padding: switch (kind) {
      StepKind.group => grouped ? _inset(AppSpacing.sm) : EdgeInsets.zero,
      StepKind.thought => _inset(inGroup ? AppSpacing.sm : AppSpacing.md),
      StepKind.command => inGroup ? _inset(AppSpacing.sm) : EdgeInsets.zero,
    },
    child: child,
  );

  static EdgeInsets _inset(double value) =>
      EdgeInsets.only(left: value, right: value, bottom: value);
}
