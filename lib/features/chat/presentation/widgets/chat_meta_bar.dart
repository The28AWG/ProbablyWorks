import 'dart:math' show min;

import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/theme/app_tokens.dart';
import 'package:probably_works/app/ui/local_host_presentation.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_density.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_motion.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Название хоста для интерфейса: локальный хост показываем переводом.
String hostLabelOf(List<Host> hosts, String hostId, AppLocalizations l10n) {
  final host = hosts.where((h) => h.id == hostId).firstOrNull;
  if (host == null) return hostId;
  return hostDisplayName(host, l10n);
}

/// Имя последней папки пути рабочей папки; null, если папка не назначена.
String? workspaceFolderName(String? path) {
  if (path == null) return null;
  final parts = path.split(RegExp(r'[/\\]')).where((p) => p.isNotEmpty);
  return parts.isEmpty ? path : parts.last;
}

/// Строка настроек чата под полем ввода: хост, папка, модель и окно контекста.
///
/// Единое правило для всех элементов: тихий чип показывает текущее значение и стрелку `▾`
/// и открывает редактор — меню (хост) или диалог (папка, модель, контекст). Хост и папка меняют
/// место выполнения, поэтому во время работы они неактивны. Режим выполнения живёт в меню «+» композера.
///
/// Чип папки появляется только когда папка назначена, чип контекста — только когда модель сообщила
/// заполнение окна. Появление и исчезновение плавные, строка не переносится на вторую линию.
///
/// Строка никогда не выходит за свою область: если чипы с подписями не помещаются, они по одному
/// сворачиваются до значка в порядке [_Chip] (см. [_collapsedChips]). Значение при этом остаётся в подсказке.
class ChatMetaBar extends StatelessWidget {
  const ChatMetaBar({
    required this.hosts,
    required this.hostId,
    required this.onHostSelected,
    required this.workspace,
    required this.onPickWorkspace,
    required this.modelLabel,
    required this.onPickModel,
    required this.contextFraction,
    required this.onOpenContext,
    required this.running,
    this.projectName,
    this.onOpenProject,
    this.modelUnavailable = false,
    this.modelLoading = false,
    this.modelPending = false,
    super.key,
  });

  final List<Host> hosts;
  final String hostId;
  final ValueChanged<String> onHostSelected;
  final String? workspace;
  final VoidCallback onPickWorkspace;

  /// Имя проекта чата. Null у нового чата до первой отправки: проект появится вместе с записью.
  final String? projectName;

  /// Открывает карточку проекта во вкладке проектов.
  final VoidCallback? onOpenProject;

  /// Null — модель не выбрана: чип предлагает выбрать её и подсвечивается предупреждением.
  final String? modelLabel;

  /// Модели больше нет в каталоге OpenRouter: чип помечается `!` и предупреждением.
  final bool modelUnavailable;

  /// Список моделей грузится впервые: рядом с названием показываем спиннер.
  final bool modelLoading;

  /// Модель ещё не известна: чат грузится, а модель по умолчанию не прочитана. Чип без текста и предупреждения,
  /// со спиннером. Когда загрузка закончится, null в [modelLabel] станет реальным предупреждением.
  final bool modelPending;
  final VoidCallback onPickModel;

  /// Доля заполненного окна контекста (0..1) или `null`, пока модель не отчиталась.
  final double? contextFraction;
  final VoidCallback onOpenContext;
  final bool running;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final current = hosts.where((h) => h.id == hostId).firstOrNull;
    final fraction = contextFraction;
    final folder = workspaceFolderName(workspace);
    final density = ChatDensityScope.of(context);
    final hostLabel = hostLabelOf(hosts, hostId, l10n);
    // Подписи в узкой области ограничены по ширине; на широкой берутся значения из темы.
    double capped(double regular) =>
        density == ChatDensity.regular ? regular : AppLayout.chipNarrowMaxWidth;
    final modelText = modelPending
        ? null
        : modelLabel == null
        ? l10n.chatModelPick
        : (modelUnavailable ? '! $modelLabel' : modelLabel);
    // Ширины считаются заранее, до раскладки: по ним решается, какие чипы свернуть до значка.
    final labeled = <_Chip, _ChipWidth?>{
      _Chip.project: projectName == null
          ? null
          : _chipWidth(context, projectName, cap: capped(160)),
      _Chip.host: _chipWidth(context, hostLabel, cap: capped(180)),
      _Chip.folder: folder == null
          ? null
          : _chipWidth(context, folder, cap: capped(140)),
      _Chip.model: _chipWidth(
        context,
        modelText,
        cap: capped(180),
        loading: modelLoading || modelPending,
      ),
      _Chip.context: fraction == null
          ? null
          : _chipWidth(
              context,
              '${(fraction * 100).round()}%',
              cap: double.infinity,
            ),
    };

    return LayoutBuilder(
      builder: (context, constraints) {
        // На очень узкой области чипы только значки всегда; иначе — сколько нужно, чтобы строка уместилась.
        final collapsed = density.iconOnlyChips
            ? _Chip.values.toSet()
            : _collapsedChips(labeled, constraints.maxWidth);
        bool iconOnly(_Chip chip) => collapsed.contains(chip);
        // Страховка от переполнения на случай расхождения округлений: строка прокручивается внутри области,
        // а не выходит за карточку композера.
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (projectName != null) ...[
                _ActionChip(
                  tooltip: l10n.chatProjectTooltip(projectName!),
                  icon: Icons.workspaces_outline,
                  label: iconOnly(_Chip.project) ? null : projectName,
                  maxWidth: capped(160),
                  onTap: onOpenProject,
                ),
                const SizedBox(width: AppSpacing.xs),
              ],
              PopupMenuButton<String>(
                tooltip: iconOnly(_Chip.host)
                    ? l10n.chatHostTooltip(hostLabel)
                    : l10n.chatHostLabel,
                enabled: !running,
                onSelected: onHostSelected,
                itemBuilder: (_) => [
                  for (final host in hosts)
                    PopupMenuItem(
                      value: host.id,
                      child: _CheckedRow(
                        checked: host.id == hostId,
                        child: Text(
                          hostDisplayName(host, l10n),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                ],
                child: ConstrainedBox(
                  // Имя хоста может быть длинным: чип ограничивается по ширине, текст обрезается многоточием.
                  constraints: BoxConstraints(maxWidth: capped(180)),
                  child: _MetaChip(
                    icon: current == null
                        ? localHostIcon()
                        : hostDisplayIcon(current),
                    label: iconOnly(_Chip.host) ? null : hostLabel,
                    enabled: !running,
                  ),
                ),
              ),
              // Папка появляется, когда назначена: без неё чип не нужен.
              ChatMorph(
                child: folder == null
                    ? const SizedBox.shrink(key: ValueKey('no-folder'))
                    : Row(
                        key: const ValueKey('folder'),
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(width: AppSpacing.xs),
                          _ActionChip(
                            tooltip: workspace ?? l10n.chatWorkspaceHint,
                            icon: Icons.folder_outlined,
                            label: iconOnly(_Chip.folder) ? null : folder,
                            maxWidth: capped(140),
                            onTap: running ? null : onPickWorkspace,
                          ),
                        ],
                      ),
              ),
              const SizedBox(width: AppSpacing.xs),
              _ActionChip(
                tooltip: modelUnavailable
                    ? l10n.chatModelUnavailableTooltip
                    : iconOnly(_Chip.model) && modelLabel != null
                    ? l10n.chatModelTooltip(modelLabel!)
                    : l10n.chatModelLabel,
                icon: Icons.memory,
                label: iconOnly(_Chip.model) || modelPending ? null : modelText,
                tone: !modelPending && (modelLabel == null || modelUnavailable)
                    ? AppTone.warning
                    : null,
                loading: modelLoading || modelPending,
                maxWidth: capped(180),
                onTap: onPickModel,
              ),
              // Окно контекста появляется, когда модель сообщила заполнение.
              ChatMorph(
                child: fraction == null
                    ? const SizedBox.shrink(key: ValueKey('no-context'))
                    : Row(
                        key: const ValueKey('context'),
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(width: AppSpacing.xs),
                          _ActionChip(
                            tooltip: iconOnly(_Chip.context)
                                ? l10n.chatContextTooltip(
                                    '${(fraction * 100).round()}',
                                  )
                                : l10n.chatContextTitle,
                            icon: Icons.data_usage,
                            label: iconOnly(_Chip.context)
                                ? null
                                : '${(fraction * 100).round()}%',
                            tone: fraction >= _warnFraction
                                ? AppTone.warning
                                : null,
                            onTap: onOpenContext,
                          ),
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Порог, с которого окно контекста подсвечивается (совпадает с порогом сжатия в агенте).
  static const _warnFraction = 0.9;
}

/// Чипы строки настроек в порядке сворачивания: сначала проект, затем хост (его значение длиннее всего),
/// потом папка, модель и контекст. Контекст сворачивается последним: его подпись короткая и нужна для оценки заполнения.
enum _Chip { project, host, folder, model, context }

/// Ширина чипа в двух состояниях: с подписью (не больше ограничения) и только значком.
typedef _ChipWidth = ({double full, double collapsed});

/// Минимальная высота чипа: одинакова у всех чипов, в том числе у чипа из одной иконки. Той же величиной
/// равна ширина чипа из одной иконки, потому что он квадратный.
const _chipMinSize = 28.0;

/// Размер иконки в чипе и толщина рамки. Рамка входит в размер чипа.
const _chipIconSize = 14.0;
const _chipBorderWidth = 1.0;

/// Ширина чипа без подписи: всё, кроме текста. Две рамки, поля по бокам, иконка, отступ до подписи,
/// отступ до стрелки и сама стрелка. Значение зависит от констант отрисовки в [_MetaChip].
const _chipLabelChrome =
    _chipBorderWidth * 2 +
    (AppSpacing.xs + 2) * 2 +
    _chipIconSize +
    AppSpacing.xs +
    2 +
    _chipIconSize;

/// Стиль подписи чипа: на узкой области мельче, чтобы строка занимала меньше ширины.
TextStyle? _chipLabelStyle(BuildContext context) {
  final theme = Theme.of(context);
  return ChatDensityScope.of(context) == ChatDensity.regular
      ? theme.textTheme.labelMedium
      : theme.textTheme.labelSmall;
}

/// Ширина чипа с подписью [text], но не больше [cap]. Текст меряется тем же стилем, что и отрисовка,
/// поэтому расчёт совпадает с тем, что потом выводится. [text] null — чип без подписи (значок и спиннер).
_ChipWidth _chipWidth(
  BuildContext context,
  String? text, {
  required double cap,
  bool loading = false,
}) {
  final spinner = loading ? AppSpacing.xs + _chipIconSize : 0.0;
  const collapsed = _chipMinSize;
  if (text == null) {
    return (full: collapsed + spinner, collapsed: collapsed + spinner);
  }
  final painter = TextPainter(
    text: TextSpan(text: text, style: _chipLabelStyle(context)),
    maxLines: 1,
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
  )..layout();
  final full = min(painter.width + _chipLabelChrome + spinner, cap);
  return (full: full, collapsed: collapsed + spinner);
}

/// Какие чипы свернуть до значка, чтобы строка с отступами уместилась в [available].
///
/// Чипы сворачиваются по одному в порядке [_Chip]: сначала самый длинный хост. Проверка «помещается ли»
/// идёт перед каждым сворачиванием, поэтому широкая строка не теряет подписи, которые ещё помещаются.
/// Чип, которого нет (папка не назначена, контекст не отчитался), в строке не участвует и не сворачивается.
Set<_Chip> _collapsedChips(Map<_Chip, _ChipWidth?> chips, double available) {
  final collapsed = <_Chip>{};
  double rowWidth() {
    var total = 0.0;
    var first = true;
    for (final chip in _Chip.values) {
      final width = chips[chip];
      if (width == null) continue;
      // Перед каждым чипом, кроме первого показанного, стоит отступ.
      if (!first) total += AppSpacing.xs;
      first = false;
      total += collapsed.contains(chip) ? width.collapsed : width.full;
    }
    return total;
  }

  for (final chip in _Chip.values) {
    if (rowWidth() <= available) break;
    if (chips[chip] != null) {
      collapsed.add(chip);
    }
  }
  return collapsed;
}

/// Строка меню с галочкой у выбранного пункта.
class _CheckedRow extends StatelessWidget {
  const _CheckedRow({required this.checked, required this.child});

  final bool checked;
  final Widget child;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 24,
        child: checked ? const Icon(Icons.check, size: 18) : null,
      ),
      Expanded(child: child),
    ],
  );
}

/// Интерактивный чип для диалога: нажимается целиком, показывает стрелку и подсказку.
class _ActionChip extends StatelessWidget {
  const _ActionChip({
    required this.tooltip,
    required this.icon,
    required this.onTap,
    this.label,
    this.maxWidth,
    this.tone,
    this.loading = false,
  });

  final String tooltip;
  final IconData icon;

  /// Null — чип показывает только иконку.
  final String? label;
  final VoidCallback? onTap;
  final double? maxWidth;
  final AppTone? tone;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final chip = _MetaChip(
      icon: icon,
      label: label,
      enabled: enabled,
      tone: tone,
      loading: loading,
    );
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: AppRadius.mdAll,
        onTap: onTap,
        child: maxWidth == null
            ? chip
            : ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxWidth!),
                child: chip,
              ),
      ),
    );
  }
}

/// Чип настройки: иконка, значение и стрелка `▾` на собственной заливке и рамке.
/// `tone` подсвечивает состояние, которое стоит заметить: почти полный контекст.
class _MetaChip extends StatelessWidget {
  const _MetaChip({
    required this.icon,
    this.label,
    this.enabled = true,
    this.tone,
    this.loading = false,
  });

  final IconData icon;

  /// Null — только иконка, без значения и стрелки.
  final String? label;
  final bool enabled;
  final AppTone? tone;

  /// Спиннер рядом со значением: название ещё не известно, список моделей грузится.
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final labelStyle = _chipLabelStyle(context);
    final colors = tone == null ? null : toneColors(context, tone!);
    final foreground = colors?.foreground ?? scheme.onSurfaceVariant;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Container(
        // Общий минимум высоты и ширины: чип из одной иконки не ниже и не уже чипов с текстом.
        constraints: const BoxConstraints(minHeight: _chipMinSize),
        // Чип из одной иконки получает симметричные отступы: иконка ровно по центру квадрата.
        padding: label == null
            ? EdgeInsets.all(
                (_chipMinSize - _chipIconSize - _chipBorderWidth * 2) / 2,
              )
            : const EdgeInsets.symmetric(
                horizontal: AppSpacing.xs + 2,
                vertical: 2,
              ),
        // Чип — отдельная кнопка, а не текст: своя заливка и рамка отличают его от фона карточки ввода.
        decoration: BoxDecoration(
          color: colors?.background ?? scheme.surface,
          borderRadius: AppRadius.mdAll,
          border: Border.all(
            width: _chipBorderWidth,
            color:
                colors?.foreground.withValues(alpha: 0.5) ??
                scheme.outlineVariant,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(icon, size: _chipIconSize, color: foreground),
            if (loading) ...[
              const SizedBox(width: AppSpacing.xs),
              SizedBox.square(
                dimension: _chipIconSize,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: foreground,
                ),
              ),
            ],
            if (label case final text?) ...[
              const SizedBox(width: AppSpacing.xs),
              Flexible(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: labelStyle?.copyWith(
                    color: colors?.foreground ?? scheme.onSurface,
                  ),
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.expand_more,
                size: _chipIconSize,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
