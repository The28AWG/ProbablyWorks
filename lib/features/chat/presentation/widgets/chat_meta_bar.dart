import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/app/theme/app_tokens.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Название хоста для интерфейса: локальный хост показываем переводом.
String hostLabelOf(List<Host> hosts, String hostId, AppLocalizations l10n) {
  final host = hosts.where((h) => h.id == hostId).firstOrNull;
  if (host == null) return hostId;
  return host.isLocal ? l10n.hostLocalName : host.name;
}

/// Настройки чата в нижней панели композера: где агент работает и с какими правами.
///
/// Единое правило для всех элементов: тихий чип показывает текущее значение и стрелку `▾`
/// и всегда открывает редактор — меню (хост, политика) или диалог (папка, модель, контекст).
/// Хост и папка меняют место выполнения, поэтому во время работы они неактивны. Политику можно
/// менять всегда: переход на «Спрашивать» во время автоматического режима — главная страховка.
/// Режим «Авто-подтверждение» выделяется тоном предупреждения.
class ChatMetaBar extends StatelessWidget {
  const ChatMetaBar({
    required this.hosts,
    required this.hostId,
    required this.onHostSelected,
    required this.workspace,
    required this.onPickWorkspace,
    required this.modelLabel,
    required this.onPickModel,
    required this.policy,
    required this.onPolicySelected,
    required this.contextFraction,
    required this.onOpenContext,
    required this.running,
    super.key,
  });

  final List<Host> hosts;
  final String hostId;
  final ValueChanged<String> onHostSelected;
  final String? workspace;
  final VoidCallback onPickWorkspace;

  /// Null — модель не выбрана: чип предлагает выбрать её и подсвечивается предупреждением.
  final String? modelLabel;
  final VoidCallback onPickModel;
  final PolicyMode policy;
  final ValueChanged<PolicyMode> onPolicySelected;

  /// Доля заполненного окна контекста (0..1) или `null`, пока модель не отчиталась.
  final double? contextFraction;
  final VoidCallback onOpenContext;
  final bool running;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final current = hosts.where((h) => h.id == hostId).firstOrNull;
    final fraction = contextFraction;

    return Wrap(
      spacing: AppSpacing.xs,
      runSpacing: AppSpacing.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
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
                  child: Text(host.isLocal ? l10n.hostLocalName : host.name),
                ),
              ),
          ],
          child: _MetaChip(
            icon: current?.isLocal ?? true
                ? Icons.computer_outlined
                : Icons.dns_outlined,
            label: hostLabelOf(hosts, hostId, l10n),
            enabled: !running,
          ),
        ),
        // Без папки чип — только иконка: подсказка объясняет, что это такое.
        _ActionChip(
          tooltip: workspace ?? l10n.chatWorkspaceHint,
          icon: Icons.folder_outlined,
          label: _folderName(workspace),
          maxWidth: 140,
          onTap: running ? null : onPickWorkspace,
        ),
        _ActionChip(
          tooltip: l10n.chatModelLabel,
          icon: Icons.memory,
          label: modelLabel ?? l10n.chatModelPick,
          tone: modelLabel == null ? AppTone.warning : null,
          maxWidth: 180,
          onTap: onPickModel,
        ),
        PopupMenuButton<PolicyMode>(
          tooltip: l10n.chatPolicyLabel,
          onSelected: onPolicySelected,
          itemBuilder: (_) => [
            _policyItem(
              context,
              mode: PolicyMode.ask,
              title: l10n.policyAsk,
              hint: l10n.policyAskHint,
            ),
            _policyItem(
              context,
              mode: PolicyMode.yolo,
              title: l10n.policyYolo,
              hint: l10n.policyYoloHint,
            ),
          ],
          child: _MetaChip(
            icon: _policyIcon(policy),
            label: policy == PolicyMode.ask ? l10n.policyAsk : l10n.policyYolo,
            tone: policy == PolicyMode.yolo ? AppTone.warning : null,
          ),
        ),
        _ActionChip(
          tooltip: l10n.chatContextTitle,
          icon: Icons.data_usage,
          label: fraction == null ? '—' : '${(fraction * 100).round()}%',
          tone: fraction != null && fraction >= _warnFraction
              ? AppTone.warning
              : null,
          onTap: onOpenContext,
        ),
      ],
    );
  }

  /// Порог, с которого окно контекста подсвечивается (совпадает с порогом сжатия в агенте).
  static const _warnFraction = 0.9;

  static String? _folderName(String? path) {
    if (path == null) return null;
    final parts = path.split(RegExp(r'[/\\]')).where((p) => p.isNotEmpty);
    return parts.isEmpty ? path : parts.last;
  }

  PopupMenuItem<PolicyMode> _policyItem(
    BuildContext context, {
    required PolicyMode mode,
    required String title,
    required String hint,
  }) {
    final theme = Theme.of(context);
    return PopupMenuItem(
      value: mode,
      child: SizedBox(
        width: 300,
        child: _CheckedRow(
          checked: mode == policy,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: theme.textTheme.titleSmall),
              const SizedBox(height: AppSpacing.xs),
              Text(
                hint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static IconData _policyIcon(PolicyMode mode) => switch (mode) {
    PolicyMode.ask => Icons.shield_outlined,
    PolicyMode.yolo => Icons.bolt_outlined,
  };
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
  });

  final String tooltip;
  final IconData icon;

  /// Null — чип показывает только иконку.
  final String? label;
  final VoidCallback? onTap;
  final double? maxWidth;
  final AppTone? tone;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final chip = _MetaChip(
      icon: icon,
      label: label,
      enabled: enabled,
      tone: tone,
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
const _chipMinSize = 32.0;

/// Размер иконки в чипе и толщина рамки. Рамка входит в размер чипа.
const _chipIconSize = 14.0;
const _chipBorderWidth = 1.0;

/// Чип настройки: иконка, значение и стрелка `▾` на собственной заливке и рамке.
/// `tone` подсвечивает состояние, которое стоит заметить: режим без подтверждений, почти полный контекст.
class _MetaChip extends StatelessWidget {
  const _MetaChip({
    required this.icon,
    this.label,
    this.enabled = true,
    this.tone,
  });

  final IconData icon;

  /// Null — только иконка, без значения и стрелки.
  final String? label;
  final bool enabled;
  final AppTone? tone;

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
                vertical: AppSpacing.xs,
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
