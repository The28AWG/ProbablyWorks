import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/theme/app_tokens.dart';
import 'package:probably_works/app/ui/local_host_presentation.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_motion.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Название хоста для интерфейса: локальный хост показываем переводом.
String hostLabelOf(List<Host> hosts, String hostId, AppLocalizations l10n) {
  final host = hosts.where((h) => h.id == hostId).firstOrNull;
  if (host == null) return hostId;
  return host.isLocal ? localHostTitle(l10n) : host.name;
}

/// Имя последней папки пути рабочей папки; null, если папка не назначена.
String? workspaceFolderName(String? path) {
  if (path == null) return null;
  final parts = path.split(RegExp(r'[/\\]')).where((p) => p.isNotEmpty);
  return parts.isEmpty ? path : parts.last;
}

/// Строка настроек чата под полем ввода: хост, модель и окно контекста.
///
/// Единое правило для всех элементов: тихий чип показывает текущее значение и стрелку `▾`
/// и открывает редактор — меню (хост) или диалог (папка, модель, контекст). Хост и папка меняют
/// место выполнения, поэтому во время работы они неактивны. Режим выполнения живёт в меню «+» композера.
///
/// Чип папки появляется только когда папка назначена, чип контекста — только когда модель сообщила
/// заполнение окна. Появление и исчезновение плавные, строка не переносится на вторую линию.
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

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PopupMenuButton<String>(
            tooltip: l10n.chatHostLabel,
            enabled: !running,
            onSelected: onHostSelected,
            itemBuilder: (_) => [
              for (final host in hosts)
                PopupMenuItem(
                  value: host.id,
                  child: _CheckedRow(
                    checked: host.id == hostId,
                    child: Text(
                      host.isLocal ? localHostTitle(l10n) : host.name,
                    ),
                  ),
                ),
            ],
            child: _MetaChip(
              icon: current?.isLocal ?? true
                  ? localHostIcon()
                  : Icons.dns_outlined,
              label: hostLabelOf(hosts, hostId, l10n),
              enabled: !running,
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
                        label: folder,
                        maxWidth: 140,
                        onTap: running ? null : onPickWorkspace,
                      ),
                    ],
                  ),
          ),
          const SizedBox(width: AppSpacing.xs),
          _ActionChip(
            tooltip: modelUnavailable
                ? l10n.chatModelUnavailableTooltip
                : l10n.chatModelLabel,
            icon: Icons.memory,
            label: modelPending
                ? null
                : modelLabel == null
                ? l10n.chatModelPick
                : (modelUnavailable ? '! $modelLabel' : modelLabel),
            tone: !modelPending && (modelLabel == null || modelUnavailable)
                ? AppTone.warning
                : null,
            loading: modelLoading || modelPending,
            maxWidth: 180,
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
                        tooltip: l10n.chatContextTitle,
                        icon: Icons.data_usage,
                        label: '${(fraction * 100).round()}%',
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
  }

  /// Порог, с которого окно контекста подсвечивается (совпадает с порогом сжатия в агенте).
  static const _warnFraction = 0.9;
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

/// Минимальная высота чипа: одинакова у всех чипов, в том числе у чипа из одной иконки.
const _chipMinSize = 28.0;

/// Размер иконки в чипе и толщина рамки. Рамка входит в размер чипа.
const _chipIconSize = 14.0;
const _chipBorderWidth = 1.0;

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
                  style: theme.textTheme.labelMedium?.copyWith(
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
